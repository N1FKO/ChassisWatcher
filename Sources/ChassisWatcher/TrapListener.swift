import Foundation
import Darwin

/// Listens for real SNMPv1 trap packets sent directly by the Areca
/// controller (or any SNMP agent) to this port over UDP. Runs entirely
/// inside the App Sandbox (com.apple.security.network.server) on an
/// unprivileged port (>1024), so no root daemon or snmptrapd is needed -
/// the Areca box is configured to send its traps straight here.
///
/// Implementation note: this originally used Network.framework's
/// NWListener + NWConnection. That was abandoned after live testing proved
/// two separate real defects in one day: (1) a listener-spawned connection
/// left open after its first datagram would wedge unrelated outbound SNMP
/// polls to the same host with a POSIX EEXIST error, and (2) even after
/// fixing that by cancelling connections promptly, NWListener would
/// sometimes hand off a brand-new connection (newConnectionHandler fired,
/// state reached .ready) whose receiveMessage completion handler then
/// simply never fired - the datagram was silently lost with no error
/// anywhere. A trap is just a single, connectionless UDP datagram, so a
/// plain POSIX socket with a background read source sidesteps NWListener's
/// per-peer "connection" abstraction (and its bugs) entirely.
final class TrapListener {
    private let port: UInt16
    private let expectedCommunity: String
    private let oids: OIDConfig
    private let smtpConfig: SMTPConfig

    private var socketFD: Int32 = -1
    private var readSource: DispatchSourceRead?
    private let queue = DispatchQueue(label: "chassiswatcher.traplistener")

    init(port: UInt16, expectedCommunity: String, oids: OIDConfig, smtpConfig: SMTPConfig) {
        self.port = port
        self.expectedCommunity = expectedCommunity
        self.oids = oids
        self.smtpConfig = smtpConfig
    }

    func start() {
        let fd = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        guard fd >= 0 else {
            Log.error("Could not create trap listener socket: \(String(cString: strerror(errno)))")
            return
        }

        var reuse: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &reuse, socklen_t(MemoryLayout<Int32>.size))

        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = in_port_t(port).bigEndian
        addr.sin_addr.s_addr = INADDR_ANY

        let bindResult = withUnsafePointer(to: &addr) { ptr -> Int32 in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPtr in
                bind(fd, sockaddrPtr, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bindResult == 0 else {
            let message = String(cString: strerror(errno))
            Log.error("Could not bind trap listener socket to port \(port): \(message)")
            close(fd)
            return
        }

        // Non-blocking: the read source only fires when data is actually
        // pending, but this guards against ever stalling this call.
        let flags = fcntl(fd, F_GETFL, 0)
        _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK)

        socketFD = fd

        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        source.setEventHandler { [weak self] in
            self?.drainSocket()
        }
        source.setCancelHandler {
            close(fd)
        }
        readSource = source
        source.resume()

        Log.info("Trap listener ready on 0.0.0.0:\(port) (accepting SNMP traps from the network, raw UDP socket)")
    }

    /// Reads every datagram currently pending on the socket (there may be
    /// more than one queued if several traps arrived close together before
    /// this handler ran).
    private func drainSocket() {
        var buffer = [UInt8](repeating: 0, count: 4096)
        while true {
            var fromAddr = sockaddr_in()
            var fromLen = socklen_t(MemoryLayout<sockaddr_in>.size)
            let bytesRead = withUnsafeMutablePointer(to: &fromAddr) { addrPtr -> Int in
                addrPtr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPtr in
                    recvfrom(socketFD, &buffer, buffer.count, 0, sockaddrPtr, &fromLen)
                }
            }
            if bytesRead > 0 {
                let senderIP = String(cString: inet_ntoa(fromAddr.sin_addr))
                let senderPort = UInt16(bigEndian: fromAddr.sin_port)
                handleDatagram(Array(buffer[0..<bytesRead]), from: "\(senderIP):\(senderPort)")
                continue
            } else if bytesRead == 0 {
                // Zero-length datagram; nothing to parse, but keep draining
                // in case more are queued.
                continue
            } else {
                let err = errno
                if err == EWOULDBLOCK || err == EAGAIN {
                    // No more data pending right now - normal, stop draining.
                    break
                }
                Log.error("Trap listener recvfrom error: \(String(cString: strerror(err)))")
                break
            }
        }
    }

    private func handleDatagram(_ bytes: [UInt8], from sender: String) {
        do {
            let trap = try SNMPClient.parseTrap(bytes)
            guard trap.community == expectedCommunity else {
                Log.warn("Ignoring SNMP trap from \(sender) with unexpected community string (got \"\(trap.community)\")")
                return
            }
            handleParsedTrap(trap)
        } catch {
            // Not a well-formed SNMP trap PDU. Log a hex preview instead of
            // silently dropping it, so unexpected input is still visible.
            let preview = bytes.prefix(32).map { String(format: "%02x", $0) }.joined(separator: " ")
            Log.warn("Received UDP datagram from \(sender) on trap port that isn't a valid SNMP trap (\(error)); first bytes: \(preview)")
        }
    }

    private func handleParsedTrap(_ trap: SNMPClient.Trap) {
        let summary = describeTrap(trap)
        Log.warn("SNMP TRAP received from \(trap.agentAddress): \(summary)")
        Notifier.send(title: "Areca SNMP trap received", body: summary)
        do {
            try SMTPMailer.send(
                subject: "[ChassisWatcher] SNMP trap received",
                body: "Trap from \(trap.agentAddress):\n\n\(summary)",
                config: smtpConfig
            )
        } catch {
            Log.error("Failed to send trap alert email: \(error)")
        }
    }

    /// Builds a human-readable summary, mapping known chassis OIDs to their
    /// friendly names (matching the same OIDs the polling engine watches)
    /// and falling back to raw OID/value pairs for anything else.
    private func describeTrap(_ trap: SNMPClient.Trap) -> String {
        let friendlyNames: [String: String] = [
            Self.normalize(oids.raidStatus): "RAID status",
            Self.normalize(oids.volumeStatus): "Volume status",
            Self.normalize(oids.cpuTemp): "CPU temperature",
            Self.normalize(oids.controllerTemp): "Controller temperature",
            Self.normalize(oids.fan1): "Fan 1",
            Self.normalize(oids.fan2): "Fan 2"
        ]

        var lines: [String] = []
        var typeLine = "Type: \(trap.genericTrapName)"
        if trap.genericTrap == 6 {
            typeLine += " (specific=\(trap.specificTrap))"
        }
        lines.append(typeLine)
        lines.append("Enterprise OID: \(trap.enterpriseOID)")

        if trap.varBinds.isEmpty {
            lines.append("(no variable bindings included)")
        } else {
            for (oid, value) in trap.varBinds.sorted(by: { $0.key < $1.key }) {
                let name = friendlyNames[Self.normalize(oid)] ?? oid
                lines.append("\(name): \(value.description)")
            }
        }
        return lines.joined(separator: "\n")
    }

    private static func normalize(_ oid: String) -> String {
        oid.hasPrefix(".") ? String(oid.dropFirst()) : oid
    }
}
