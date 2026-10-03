import Foundation

final class PollingEngine {
    private var config: AppConfig
    private var client: SNMPClient
    // AlertManager deliberately survives config reloads: it holds the
    // in-memory "is this condition currently active" state that powers the
    // recovered-notice logic. We want threshold tweaks to take effect live,
    // without wiping out an alert that's already in progress.
    private let alertManager: AlertManager
    private var consecutiveFailures = 0
    private var configFileModifiedAt: Date?

    // SNMP responses decode OIDs without a leading dot, but config files may
    // (or may not) include one. Normalize once here so request encoding and
    // response lookups always agree on the same key.
    private var oidRaid: String = ""
    private var oidVolume: String = ""
    private var oidCPUTemp: String = ""
    private var oidControllerTemp: String = ""
    private var oidFan1: String = ""
    private var oidFan2: String = ""
    private var oidUptime: String = ""

    private static func normalize(_ oid: String) -> String {
        oid.hasPrefix(".") ? String(oid.dropFirst()) : oid
    }

    init(config: AppConfig) {
        self.config = config
        self.client = SNMPClient(host: config.host, port: config.snmpPort, community: config.community)
        self.alertManager = AlertManager(repeatAlertIntervalSeconds: config.repeatAlertIntervalSeconds)
        applyConfig(config)
        configFileModifiedAt = (try? FileManager.default.attributesOfItem(atPath: ConfigLoader.configFileURL.path))?[.modificationDate] as? Date
    }

    private func applyConfig(_ newConfig: AppConfig) {
        self.config = newConfig
        Log.updateRetentionDays(newConfig.logRetentionDays)
        self.client = SNMPClient(host: newConfig.host, port: newConfig.snmpPort, community: newConfig.community)
        self.oidRaid = Self.normalize(newConfig.oids.raidStatus)
        self.oidVolume = Self.normalize(newConfig.oids.volumeStatus)
        self.oidCPUTemp = Self.normalize(newConfig.oids.cpuTemp)
        self.oidControllerTemp = Self.normalize(newConfig.oids.controllerTemp)
        self.oidFan1 = Self.normalize(newConfig.oids.fan1)
        self.oidFan2 = Self.normalize(newConfig.oids.fan2)
        self.oidUptime = Self.normalize(newConfig.oids.uptime)
    }

    /// Re-reads config.json before each poll if it changed on disk, so
    /// threshold/config edits take effect live without a restart (and
    /// without resetting alertManager's in-progress alert state).
    private func reloadConfigIfChanged() {
        let url = ConfigLoader.configFileURL
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              let modifiedAt = attrs[.modificationDate] as? Date else {
            return
        }
        if let last = configFileModifiedAt, modifiedAt <= last {
            return
        }
        configFileModifiedAt = modifiedAt
        do {
            let data = try Data(contentsOf: url)
            let newConfig = try JSONDecoder().decode(AppConfig.self, from: data)
            applyConfig(newConfig)
            Log.info("Reloaded config.json (picked up on-disk changes).")
        } catch {
            Log.error("Failed to reload config.json, keeping previous settings: \(error)")
        }
    }

    func start() {
        Log.info("Starting poll loop: host=\(config.host) interval=\(config.pollIntervalSeconds)s")
        Task {
            while true {
                await pollOnce()
                try? await Task.sleep(nanoseconds: UInt64(config.pollIntervalSeconds * 1_000_000_000))
            }
        }
    }

    private func pollOnce() async {
        reloadConfigIfChanged()
        let oids = [oidRaid, oidVolume, oidCPUTemp, oidControllerTemp, oidFan1, oidFan2, oidUptime]

        do {
            let values = try await client.get(oids: oids)
            consecutiveFailures = 0
            logSummary(values)
            evaluate(values)
        } catch {
            consecutiveFailures += 1
            Log.error("Poll failed (\(consecutiveFailures) in a row): \(error)")
            alertManager.evaluate(
                key: "poll_failure",
                isOutOfRange: consecutiveFailures >= 3,
                title: "ChassisWatcher: can't reach Areca box",
                body: "Failed to poll \(config.host) \(consecutiveFailures) times in a row. Last error: \(error)",
                recoveredBody: "Polling \(config.host) is working again.",
                sendEmail: true,
                smtpConfig: config.smtp
            )
        }
    }

    private func evaluate(_ values: [String: SNMPValue]) {
        // RAID status
        if let raid = values[oidRaid] {
            let raidString = raid.description
            alertManager.evaluate(
                key: "raid_status",
                isOutOfRange: raidString != config.healthyRaidStatus,
                title: "Areca RAID status: \(raidString)",
                body: "RAID status reports \"\(raidString)\" (expected \"\(config.healthyRaidStatus)\").",
                recoveredBody: "RAID status is back to \"\(config.healthyRaidStatus)\".",
                sendEmail: true,
                smtpConfig: config.smtp
            )
        } else {
            Log.warn("RAID status OID missing from response")
        }

        // Volume status
        if let volume = values[oidVolume] {
            let volumeString = volume.description
            alertManager.evaluate(
                key: "volume_status",
                isOutOfRange: volumeString != config.healthyVolumeStatus,
                title: "Areca volume status: \(volumeString)",
                body: "Volume status reports \"\(volumeString)\" (expected \"\(config.healthyVolumeStatus)\").",
                recoveredBody: "Volume status is back to \"\(config.healthyVolumeStatus)\".",
                sendEmail: true,
                smtpConfig: config.smtp
            )
        } else {
            Log.warn("Volume status OID missing from response")
        }

        // CPU temp (Areca reports these as whole-degree integers)
        if let cpuTempValue = numericValue(values[oidCPUTemp]) {
            let critical = cpuTempValue >= config.thresholds.cpuTempCriticalC
            let warn = cpuTempValue >= config.thresholds.cpuTempWarnC
            alertManager.evaluate(
                key: "cpu_temp",
                isOutOfRange: warn,
                title: critical ? "CPU temp CRITICAL: \(Int(cpuTempValue))°C" : "CPU temp high: \(Int(cpuTempValue))°C",
                body: "CPU/processor temperature is \(Int(cpuTempValue))°C (warn ≥\(Int(config.thresholds.cpuTempWarnC))°C, critical ≥\(Int(config.thresholds.cpuTempCriticalC))°C).",
                recoveredBody: "CPU temperature back under \(Int(config.thresholds.cpuTempWarnC))°C.",
                sendEmail: true,
                smtpConfig: config.smtp
            )
        } else {
            Log.warn("CPU temp OID missing or non-numeric")
        }

        // Controller temp
        if let controllerTempValue = numericValue(values[oidControllerTemp]) {
            let critical = controllerTempValue >= config.thresholds.controllerTempCriticalC
            let warn = controllerTempValue >= config.thresholds.controllerTempWarnC
            alertManager.evaluate(
                key: "controller_temp",
                isOutOfRange: warn,
                title: critical ? "Controller temp CRITICAL: \(Int(controllerTempValue))°C" : "Controller temp high: \(Int(controllerTempValue))°C",
                body: "Controller board temperature is \(Int(controllerTempValue))°C (warn ≥\(Int(config.thresholds.controllerTempWarnC))°C, critical ≥\(Int(config.thresholds.controllerTempCriticalC))°C).",
                recoveredBody: "Controller temperature back under \(Int(config.thresholds.controllerTempWarnC))°C.",
                sendEmail: true,
                smtpConfig: config.smtp
            )
        } else {
            Log.warn("Controller temp OID missing or non-numeric")
        }

        // Fans
        evaluateFan(name: "Fan 1", oid: oidFan1, key: "fan1", values: values)
        evaluateFan(name: "Fan 2", oid: oidFan2, key: "fan2", values: values)
    }

    private func logSummary(_ values: [String: SNMPValue]) {
        let raid = values[oidRaid]?.description ?? "?"
        let volume = values[oidVolume]?.description ?? "?"
        let cpu = numericValue(values[oidCPUTemp]).map { "\(Int($0))°C" } ?? "?"
        let controller = numericValue(values[oidControllerTemp]).map { "\(Int($0))°C" } ?? "?"
        let fan1 = numericValue(values[oidFan1]).map { "\(Int($0)) RPM" } ?? "?"
        let fan2 = numericValue(values[oidFan2]).map { "\(Int($0)) RPM" } ?? "?"
        Log.info("Poll OK: raid=\(raid) volume=\(volume) cpuTemp=\(cpu) controllerTemp=\(controller) fan1=\(fan1) fan2=\(fan2)")
    }

    private func evaluateFan(name: String, oid: String, key: String, values: [String: SNMPValue]) {
        guard let rpm = numericValue(values[oid]) else {
            Log.warn("\(name) OID missing or non-numeric")
            return
        }
        let low = rpm < Double(config.thresholds.fanMinRPM)
        alertManager.evaluate(
            key: key,
            isOutOfRange: low,
            title: "\(name) speed low: \(Int(rpm)) RPM",
            body: "\(name) is reporting \(Int(rpm)) RPM, below the \(config.thresholds.fanMinRPM) RPM threshold.",
            recoveredBody: "\(name) is back above \(config.thresholds.fanMinRPM) RPM.",
            sendEmail: true,
            smtpConfig: config.smtp
        )
    }

    private func numericValue(_ value: SNMPValue?) -> Double? {
        guard let value = value else { return nil }
        switch value {
        case .integer(let i): return Double(i)
        case .string(let s): return Double(s.trimmingCharacters(in: .whitespaces))
        case .raw: return nil
        }
    }
}
