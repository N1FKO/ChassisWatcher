import Foundation

struct Thresholds: Codable {
    var controllerTempWarnC: Double
    var controllerTempCriticalC: Double
    var cpuTempWarnC: Double
    var cpuTempCriticalC: Double
    var fanMinRPM: Int
}

struct SMTPConfig: Codable {
    var host: String
    var port: UInt16
    var username: String
    var password: String
    var fromAddress: String
    var toAddress: String
    var useSTARTTLS: Bool
}

struct OIDConfig: Codable {
    var raidStatus: String
    var volumeStatus: String
    var cpuTemp: String
    var controllerTemp: String
    var fan1: String
    var fan2: String
    var uptime: String
}

struct AppConfig: Codable {
    var host: String
    var snmpPort: UInt16
    var community: String
    var pollIntervalSeconds: Double
    var thresholds: Thresholds
    var healthyRaidStatus: String
    var healthyVolumeStatus: String
    var smtp: SMTPConfig
    var trapListenPort: UInt16
    var oids: OIDConfig
    // Minimum seconds between repeat emails for the *same* ongoing alert condition,
    // so we don't send an email every single poll while something stays out of range.
    var repeatAlertIntervalSeconds: Double
    // Rotated daily logs (chassiswatcher-YYYY-MM-DD.log) older than this many
    // days are deleted automatically. The live chassiswatcher.log is never
    // deleted by this - only its past rotations. Applied live on config reload.
    var logRetentionDays: Int

    static let defaultConfig = AppConfig(
        host: "192.168.1.100",
        snmpPort: 161,
        community: "public",
        pollIntervalSeconds: 60,
        thresholds: Thresholds(
            controllerTempWarnC: 60,
            controllerTempCriticalC: 65,
            cpuTempWarnC: 85,
            cpuTempCriticalC: 95,
            fanMinRPM: 500
        ),
        healthyRaidStatus: "Normal",
        healthyVolumeStatus: "Normal",
        smtp: SMTPConfig(
            host: "smtp.example.com",
            port: 587,
            username: "alerts@example.com",
            password: "REPLACE_ME",
            fromAddress: "ChassisWatcher <alerts@example.com>",
            toAddress: "you@example.com",
            useSTARTTLS: true
        ),
        trapListenPort: 16200,
        oids: OIDConfig(
            raidStatus: ".1.3.6.1.4.1.18928.1.2.4.1.1.4.0",
            volumeStatus: ".1.3.6.1.4.1.18928.1.2.5.1.1.5.0",
            cpuTemp: ".1.3.6.1.4.1.18928.1.2.2.1.10.1.3.1",
            controllerTemp: ".1.3.6.1.4.1.18928.1.2.2.1.10.1.3.2",
            fan1: ".1.3.6.1.4.1.18928.1.2.2.2.9.1.3.1",
            fan2: ".1.3.6.1.4.1.18928.1.2.2.2.9.1.3.2",
            uptime: ".1.3.6.1.2.1.1.3.0"
        ),
        repeatAlertIntervalSeconds: 3600,
        logRetentionDays: 90
    )

    // Custom Decodable so config.json files saved before logRetentionDays
    // existed (or any future added field) still load, defaulting missing
    // keys instead of throwing. Encoding stays auto-synthesized.
    enum CodingKeys: String, CodingKey {
        case host, snmpPort, community, pollIntervalSeconds, thresholds
        case healthyRaidStatus, healthyVolumeStatus, smtp, trapListenPort, oids
        case repeatAlertIntervalSeconds, logRetentionDays
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        host = try c.decode(String.self, forKey: .host)
        snmpPort = try c.decode(UInt16.self, forKey: .snmpPort)
        community = try c.decode(String.self, forKey: .community)
        pollIntervalSeconds = try c.decode(Double.self, forKey: .pollIntervalSeconds)
        thresholds = try c.decode(Thresholds.self, forKey: .thresholds)
        healthyRaidStatus = try c.decode(String.self, forKey: .healthyRaidStatus)
        healthyVolumeStatus = try c.decode(String.self, forKey: .healthyVolumeStatus)
        smtp = try c.decode(SMTPConfig.self, forKey: .smtp)
        trapListenPort = try c.decode(UInt16.self, forKey: .trapListenPort)
        oids = try c.decode(OIDConfig.self, forKey: .oids)
        repeatAlertIntervalSeconds = try c.decode(Double.self, forKey: .repeatAlertIntervalSeconds)
        logRetentionDays = try c.decodeIfPresent(Int.self, forKey: .logRetentionDays) ?? AppConfig.defaultConfig.logRetentionDays
    }

    init(host: String, snmpPort: UInt16, community: String, pollIntervalSeconds: Double,
         thresholds: Thresholds, healthyRaidStatus: String, healthyVolumeStatus: String,
         smtp: SMTPConfig, trapListenPort: UInt16, oids: OIDConfig,
         repeatAlertIntervalSeconds: Double, logRetentionDays: Int) {
        self.host = host
        self.snmpPort = snmpPort
        self.community = community
        self.pollIntervalSeconds = pollIntervalSeconds
        self.thresholds = thresholds
        self.healthyRaidStatus = healthyRaidStatus
        self.healthyVolumeStatus = healthyVolumeStatus
        self.smtp = smtp
        self.trapListenPort = trapListenPort
        self.oids = oids
        self.repeatAlertIntervalSeconds = repeatAlertIntervalSeconds
        self.logRetentionDays = logRetentionDays
    }
}

enum ConfigLoader {
    static var configDirectory: URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return appSupport.appendingPathComponent("ChassisWatcher", isDirectory: true)
    }

    static var configFileURL: URL {
        configDirectory.appendingPathComponent("config.json")
    }

    /// Loads config.json, creating it with defaults on first run so there is
    /// always something to edit at a predictable path.
    static func loadOrCreateDefault() throws -> AppConfig {
        let fm = FileManager.default
        if !fm.fileExists(atPath: configDirectory.path) {
            try fm.createDirectory(at: configDirectory, withIntermediateDirectories: true)
        }
        if !fm.fileExists(atPath: configFileURL.path) {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(AppConfig.defaultConfig)
            try data.write(to: configFileURL)
            Log.info("Created default config at \(configFileURL.path). Edit it (especially the SMTP password) before relying on email alerts.")
        }
        let data = try Data(contentsOf: configFileURL)
        let decoder = JSONDecoder()
        return try decoder.decode(AppConfig.self, from: data)
    }
}
