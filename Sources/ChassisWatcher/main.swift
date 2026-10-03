import Foundation
import ServiceManagement

Log.info("ChassisWatcher starting up")

// Register as a login item so the app relaunches automatically after every
// reboot/login, without needing a LaunchAgent plist or any root/sudo setup.
func registerLoginItemIfNeeded() {
    let service = SMAppService.mainApp
    switch service.status {
    case .notRegistered, .notFound:
        do {
            try service.register()
            Log.info("Registered ChassisWatcher as a login item (will launch automatically at login).")
        } catch {
            Log.error("Failed to register as login item: \(error). You can register manually in System Settings > General > Login Items.")
        }
    case .enabled:
        Log.info("Login item already registered and enabled.")
    case .requiresApproval:
        Log.warn("Login item registered but requires approval - enable ChassisWatcher in System Settings > General > Login Items.")
    default:
        Log.info("Login item status: \(service.status.rawValue)")
    }
}

registerLoginItemIfNeeded()

let config: AppConfig
do {
    config = try ConfigLoader.loadOrCreateDefault()
} catch {
    Log.error("Failed to load config: \(error)")
    exit(1)
}

if config.smtp.password == "REPLACE_ME" {
    Log.warn("SMTP password in \(ConfigLoader.configFileURL.path) is still the placeholder - email alerts will fail until you set a real password.")
}

Notifier.requestAuthorizationIfNeeded()

let trapListener = TrapListener(
    port: config.trapListenPort,
    expectedCommunity: config.community,
    oids: config.oids,
    smtpConfig: config.smtp
)
trapListener.start()

let pollingEngine = PollingEngine(config: config)
pollingEngine.start()

Log.info("ChassisWatcher running. Config: \(ConfigLoader.configFileURL.path)")

// Keep the process alive; everything else runs on background tasks/queues.
RunLoop.main.run()
