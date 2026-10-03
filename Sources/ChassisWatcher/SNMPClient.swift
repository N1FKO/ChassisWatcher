import Foundation
import Network

enum SNMPValue {
    case integer(Int)
    case string(String)
    case raw(tag: UInt8, bytes: [UInt8])

    var description: String {
        switch self {
        case .integer(let v): return String(v)
        case .string(let s): return s
        case .raw(let tag, let bytes): return "raw(tag=0x\(String(tag, radix: 16)), \(bytes.count) bytes)"
        }
    }
}

enum SNMPError: Error, CustomStringConvertible {
    case timeout
    case connectionFailed(String)
    case malformedResponse(String)
    case errorStatus(Int, Int) // (errorStatus, errorIndex)

    var description: String {
        switch self {
        case .timeout: return "SNMP request timed out"
        case .connectionFailed(let msg): return "SNMP connection failed: \(msg)"
        case .malformedResponse(let msg): return "SNMP malformed response: \(msg)"
        case .errorStatus(let status, let index): return "SNMP error status \(status) at index \(index)"
        }
    }
}

/// A minimal SNMPv1 GET client built on Network.framework UDP, so it works
/// inside an App Sandbox without shelling out to net-snmp binaries.
final class SNMPClient {
    private let host: String
    private let port: UInt16
    private let community: String
    private let timeoutSeconds: Double

    private static var requestIDCounter = Int32.random(in: 1...100000)

    init(host: String, port: UInt16 = 161, community: String, timeoutSeconds: Double = 4.0) {
        self.host = host
        self.port = port
        self.community = community
        self.timeoutSeconds = timeoutSeconds
    }

    /// Fetches multiple OIDs in a single GetRequest PDU for efficiency, returning
    /// a dictionary of OID -> SNMPValue. Throws if the transport fails or the
    /// response cannot be parsed; individual missing OIDs are simply absent
    /// from the result if the agent reports noSuchName without a hard error.
    func get(oids: [String]) async throws -> [String: SNMPValue] {
        let requestID = Int(nextRequestID())
        let packet = try buildGetRequest(requestID: requestID, oids: oids)
        let responseData = try await sendAndReceive(packet)
        return try Self.parseGetResponse(responseData, expectedRequestID: requestID)
    }

    private func nextRequestID() -> Int32 {
        SNMPClient.requestIDCounter += 1
        return SNMPClient.requestIDCounter
    }

    private func buildGetRequest(requestID: Int, oids: [String]) throws -> [UInt8] {
        var varBinds: [UInt8] = []
        for oid in oids {
            let varBind = BER.encodeSequence(BER.encodeOID(oid) + BER.encodeNull())
            varBinds.append(contentsOf: varBind)
        }
        let varBindList = BER.encodeSequence(varBinds)

        let pduContent = BER.encodeInteger(requestID)
            + BER.encodeInteger(0) // error-status
            + BER.encodeInteger(0) // error-index
            + varBindList

        let pdu = BER.encodeConstructed(tag: BERTag.getRequestPDU.rawValue, content: pduContent)

        let messageContent = BER.encodeInteger(0) // SNMP version 1 = value 0
            + BER.encodeOctetString(community)
            + pdu

        return BER.encodeSequence(messageContent)
    }

    private func sendAndReceive(_ packet: [UInt8]) async throws -> [UInt8] {
        let connection = NWConnection(
            host: NWEndpoint.Host(host),
            port: NWEndpoint.Port(rawValue: port)!,
            using: .udp
        )

        return try await withCheckedThrowingContinuation { continuation in
            var didResume = false
            var lastWaitingError: String?
            let resumeLock = NSLock()
            func resumeOnce(_ result: Result<[UInt8], Error>) {
                resumeLock.lock()
                defer { resumeLock.unlock() }
                guard !didResume else { return }
                didResume = true
                connection.cancel()
                switch result {
                case .success(let data): continuation.resume(returning: data)
                case .failure(let error): continuation.resume(throwing: error)
                }
            }

            connection.stateUpdateHandler = { [host, port] state in
                switch state {
                case .ready:
                    let data = Data(packet)
                    connection.send(content: data, completion: .contentProcessed { error in
                        if let error = error {
                            resumeOnce(.failure(SNMPError.connectionFailed("send: \(error)")))
                            return
                        }
                        connection.receiveMessage { content, _, _, error in
                            if let error = error {
                                resumeOnce(.failure(SNMPError.connectionFailed("receive: \(error)")))
                                return
                            }
                            guard let content = content else {
                                resumeOnce(.failure(SNMPError.connectionFailed("empty response")))
                                return
                            }
                            resumeOnce(.success([UInt8](content)))
                        }
                    })
                case .failed(let error):
                    resumeOnce(.failure(SNMPError.connectionFailed("\(error)")))
                case .waiting(let error):
                    // Don't fail immediately - .waiting can be transient (e.g. brief
                    // route re-evaluation) and often resolves to .ready on its own.
                    // But DO capture the reason so a subsequent timeout has real
                    // diagnostic detail instead of just "timed out".
                    let description = "\(error)"
                    if description != lastWaitingError {
                        lastWaitingError = description
                        Log.warn("SNMP connection to \(host):\(port) is waiting (not yet failing): \(description)")
                    }
                default:
                    break
                }
            }

            let queue = DispatchQueue(label: "snmp.client.\(UUID().uuidString)")
            connection.start(queue: queue)

            queue.asyncAfter(deadline: .now() + self.timeoutSeconds) {
                if let waitingError = lastWaitingError {
                    resumeOnce(.failure(SNMPError.connectionFailed("timed out while connection was stuck waiting: \(waitingError)")))
                } else {
                    resumeOnce(.failure(SNMPError.timeout))
                }
            }
        }
    }

    /// Parses an SNMPv1 GetResponse message and returns OID -> value pairs.
    static func parseGetResponse(_ data: [UInt8], expectedRequestID: Int?) throws -> [String: SNMPValue] {
        // Outer SEQUENCE
        let (outerTag, outerContent, _) = try BER.parseTLV(data, at: 0)
        guard outerTag == BERTag.sequence.rawValue else {
            throw SNMPError.malformedResponse("expected outer SEQUENCE, got tag 0x\(String(outerTag, radix: 16))")
        }

        var offset = 0
        // version INTEGER
        let (versionTag, _, afterVersion) = try BER.parseTLV(outerContent, at: offset)
        guard versionTag == BERTag.integer.rawValue else {
            throw SNMPError.malformedResponse("expected version INTEGER")
        }
        offset = afterVersion

        // community OCTET STRING
        let (communityTag, _, afterCommunity) = try BER.parseTLV(outerContent, at: offset)
        guard communityTag == BERTag.octetString.rawValue else {
            throw SNMPError.malformedResponse("expected community OCTET STRING")
        }
        offset = afterCommunity

        // PDU (context-constructed tag, expect GetResponse = 0xA2)
        let (pduTag, pduContent, _) = try BER.parseTLV(outerContent, at: offset)
        guard pduTag == BERTag.getResponsePDU.rawValue else {
            throw SNMPError.malformedResponse("expected GetResponse PDU, got tag 0x\(String(pduTag, radix: 16))")
        }

        var pduOffset = 0
        let (_, requestIDBytes, afterReqID) = try BER.parseTLV(pduContent, at: pduOffset)
        let requestID = BER.decodeInteger(requestIDBytes)
        pduOffset = afterReqID
        if let expected = expectedRequestID, requestID != expected {
            throw SNMPError.malformedResponse("request-id mismatch: expected \(expected), got \(requestID)")
        }

        let (_, errorStatusBytes, afterErrStatus) = try BER.parseTLV(pduContent, at: pduOffset)
        let errorStatus = BER.decodeInteger(errorStatusBytes)
        pduOffset = afterErrStatus

        let (_, errorIndexBytes, afterErrIndex) = try BER.parseTLV(pduContent, at: pduOffset)
        let errorIndex = BER.decodeInteger(errorIndexBytes)
        pduOffset = afterErrIndex

        if errorStatus != 0 {
            throw SNMPError.errorStatus(errorStatus, errorIndex)
        }

        let (varBindListTag, varBindListContent, _) = try BER.parseTLV(pduContent, at: pduOffset)
        guard varBindListTag == BERTag.sequence.rawValue else {
            throw SNMPError.malformedResponse("expected VarBindList SEQUENCE")
        }

        return try parseVarBindList(varBindListContent)
    }

    /// Shared by GetResponse and Trap PDU parsing: decodes a VarBindList
    /// SEQUENCE (a sequence of OID/value SEQUENCE pairs) into a dictionary.
    static func parseVarBindList(_ varBindListContent: [UInt8]) throws -> [String: SNMPValue] {
        var results: [String: SNMPValue] = [:]
        var vbOffset = 0
        while vbOffset < varBindListContent.count {
            let (vbTag, vbContent, nextVb) = try BER.parseTLV(varBindListContent, at: vbOffset)
            guard vbTag == BERTag.sequence.rawValue else {
                throw SNMPError.malformedResponse("expected VarBind SEQUENCE")
            }
            var inner = 0
            let (oidTag, oidBytes, afterOid) = try BER.parseTLV(vbContent, at: inner)
            guard oidTag == BERTag.objectIdentifier.rawValue else {
                throw SNMPError.malformedResponse("expected OID in VarBind")
            }
            inner = afterOid
            let oidString = BER.decodeOID(oidBytes)

            let (valueTag, valueBytes, _) = try BER.parseTLV(vbContent, at: inner)
            let value: SNMPValue
            switch valueTag {
            case BERTag.integer.rawValue, 0x41, 0x42, 0x43: // INTEGER, Counter32, Gauge32, TimeTicks
                value = .integer(BER.decodeInteger(valueBytes))
            case BERTag.octetString.rawValue:
                value = .string(String(decoding: valueBytes, as: UTF8.self))
            default:
                value = .raw(tag: valueTag, bytes: valueBytes)
            }
            results[oidString] = value

            vbOffset = nextVb
        }

        return results
    }

    // MARK: - Trap PDU parsing

    static let genericTrapNames = [
        0: "coldStart", 1: "warmStart", 2: "linkDown", 3: "linkUp",
        4: "authenticationFailure", 5: "egpNeighborLoss", 6: "enterpriseSpecific"
    ]

    struct Trap {
        let community: String
        let enterpriseOID: String
        let agentAddress: String
        let genericTrap: Int
        let specificTrap: Int
        let timestamp: Int
        let varBinds: [String: SNMPValue]

        var genericTrapName: String {
            SNMPClient.genericTrapNames[genericTrap] ?? "unknown(\(genericTrap))"
        }
    }

    /// Parses a raw SNMPv1 Trap-PDU message (as sent directly by a device like
    /// the Areca controller to a configured trap-receiver port). This is a
    /// real BER-encoded SNMP message, not a text summary.
    static func parseTrap(_ data: [UInt8]) throws -> Trap {
        let (outerTag, outerContent, _) = try BER.parseTLV(data, at: 0)
        guard outerTag == BERTag.sequence.rawValue else {
            throw SNMPError.malformedResponse("expected outer SEQUENCE, got tag 0x\(String(outerTag, radix: 16))")
        }

        var offset = 0
        let (versionTag, _, afterVersion) = try BER.parseTLV(outerContent, at: offset)
        guard versionTag == BERTag.integer.rawValue else {
            throw SNMPError.malformedResponse("expected version INTEGER")
        }
        offset = afterVersion

        let (communityTag, communityBytes, afterCommunity) = try BER.parseTLV(outerContent, at: offset)
        guard communityTag == BERTag.octetString.rawValue else {
            throw SNMPError.malformedResponse("expected community OCTET STRING")
        }
        let community = String(decoding: communityBytes, as: UTF8.self)
        offset = afterCommunity

        let (pduTag, pduContent, _) = try BER.parseTLV(outerContent, at: offset)
        guard pduTag == BERTag.trapPDU.rawValue else {
            throw SNMPError.malformedResponse("expected Trap PDU, got tag 0x\(String(pduTag, radix: 16))")
        }

        var pduOffset = 0
        let (_, enterpriseBytes, afterEnterprise) = try BER.parseTLV(pduContent, at: pduOffset)
        let enterpriseOID = BER.decodeOID(enterpriseBytes)
        pduOffset = afterEnterprise

        let (_, agentAddrBytes, afterAgent) = try BER.parseTLV(pduContent, at: pduOffset)
        let agentAddress = agentAddrBytes.map { String($0) }.joined(separator: ".")
        pduOffset = afterAgent

        let (_, genericBytes, afterGeneric) = try BER.parseTLV(pduContent, at: pduOffset)
        let genericTrap = BER.decodeInteger(genericBytes)
        pduOffset = afterGeneric

        let (_, specificBytes, afterSpecific) = try BER.parseTLV(pduContent, at: pduOffset)
        let specificTrap = BER.decodeInteger(specificBytes)
        pduOffset = afterSpecific

        let (_, timestampBytes, afterTimestamp) = try BER.parseTLV(pduContent, at: pduOffset)
        let timestamp = BER.decodeInteger(timestampBytes)
        pduOffset = afterTimestamp

        let (varBindListTag, varBindListContent, _) = try BER.parseTLV(pduContent, at: pduOffset)
        guard varBindListTag == BERTag.sequence.rawValue else {
            throw SNMPError.malformedResponse("expected VarBindList SEQUENCE in trap")
        }
        let varBinds = try parseVarBindList(varBindListContent)

        return Trap(
            community: community,
            enterpriseOID: enterpriseOID,
            agentAddress: agentAddress,
            genericTrap: genericTrap,
            specificTrap: specificTrap,
            timestamp: timestamp,
            varBinds: varBinds
        )
    }
}
