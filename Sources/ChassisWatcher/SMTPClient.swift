import Foundation

/// Sends mail via /usr/bin/curl's built-in SMTP support rather than hand-rolling
/// a STARTTLS + AUTH + TLS state machine in Swift. curl's SMTP implementation is
/// mature and well-tested; this keeps the alerting path simple and reliable.
/// The spawned curl process inherits this app's sandbox container, so the
/// network.client entitlement covers it too.
enum SMTPError: Error, CustomStringConvertible {
    case curlNotFound
    case processFailed(Int32, String)

    var description: String {
        switch self {
        case .curlNotFound: return "curl not found at /usr/bin/curl"
        case .processFailed(let code, let output): return "curl exited with status \(code): \(output)"
        }
    }
}

enum SMTPMailer {

    /// Extracts a bare "user@host" address out of a "Display Name <user@host>"
    /// style string, or returns the input unchanged if there are no angle brackets.
    static func bareAddress(_ address: String) -> String {
        if let start = address.firstIndex(of: "<"), let end = address.firstIndex(of: ">"), start < end {
            let inner = address[address.index(after: start)..<end]
            return String(inner).trimmingCharacters(in: .whitespaces)
        }
        return address.trimmingCharacters(in: .whitespaces)
    }

    static func rfc2822Date() -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss Z"
        return formatter.string(from: Date())
    }

    static func buildMessage(subject: String, body: String, config: SMTPConfig) -> String {
        let messageID = "<\(UUID().uuidString)@chassiswatcher.local>"
        var lines: [String] = []
        lines.append("From: \(config.fromAddress)")
        lines.append("To: \(config.toAddress)")
        lines.append("Subject: \(subject)")
        lines.append("Date: \(rfc2822Date())")
        lines.append("Message-ID: \(messageID)")
        lines.append("Content-Type: text/plain; charset=utf-8")
        lines.append("")
        lines.append(body)
        return lines.joined(separator: "\r\n")
    }

    static func send(subject: String, body: String, config: SMTPConfig) throws {
        let curlPath = "/usr/bin/curl"
        guard FileManager.default.isExecutableFile(atPath: curlPath) else {
            throw SMTPError.curlNotFound
        }

        let message = buildMessage(subject: subject, body: body, config: config)
        let fromBare = bareAddress(config.fromAddress)
        let toBare = bareAddress(config.toAddress)
        let scheme = config.useSTARTTLS ? "smtp" : "smtps"

        var args: [String] = [
            "--silent", "--show-error",
            "--url", "\(scheme)://\(config.host):\(config.port)",
            "--mail-from", fromBare,
            "--mail-rcpt", toBare,
            "--user", "\(config.username):\(config.password)",
            "--upload-file", "-",
            "--connect-timeout", "10",
            "--max-time", "20",
        ]
        if config.useSTARTTLS {
            args.append("--ssl-reqd")
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: curlPath)
        process.arguments = args

        let inputPipe = Pipe()
        let outputPipe = Pipe()
        process.standardInput = inputPipe
        process.standardOutput = outputPipe
        process.standardError = outputPipe

        try process.run()
        if let data = message.data(using: .utf8) {
            inputPipe.fileHandleForWriting.write(data)
        }
        inputPipe.fileHandleForWriting.closeFile()
        process.waitUntilExit()

        let outputData = outputPipe.fileHandleForReading.readDataToEndOfFile()
        let outputText = String(data: outputData, encoding: .utf8) ?? ""

        if process.terminationStatus != 0 {
            throw SMTPError.processFailed(process.terminationStatus, outputText)
        }
    }
}
