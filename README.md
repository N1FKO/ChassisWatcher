# ChassisWatcher

A small, windowless macOS background app that monitors an Areca RAID enclosure over SNMP.

- Polls chassis health every N seconds (SNMPv1): CPU temperature, controller temperature, fan 1 and fan 2 speed, RAID status, and volume status.
- Alerts (macOS notification and email) when a value leaves the ranges you configure, or when the enclosure becomes unreachable.
- Listens for SNMP traps sent by the enclosure and alerts on those too.
- Writes a daily-rotated log with configurable retention.
- Includes an optional weekly summary script (highs/lows of every metric plus a data-freshness check), scheduled with launchd.

It is written in Swift with no third-party dependencies, runs as a sandboxed `LSUIElement` app (no Dock icon), and registers itself as a login item.

Developed against an Areca ARC-8050T1. The default OIDs in `Config.swift` come from Areca's enterprise MIB (1.3.6.1.4.1.18928); other models may use different OIDs, which you can change in the config file.

## Requirements

- macOS 13 or later (Apple Silicon or Intel)
- Xcode command line tools (`xcode-select --install`) providing the Swift toolchain
- SNMP enabled on the Areca controller (community string, and a trap destination pointing at this Mac)

## Build and run

```sh
./build_app.sh
open ChassisWatcher.app
```

The script builds a release binary, assembles the `.app` bundle, and signs it ad hoc with the App Sandbox and network entitlements. To keep it, copy it somewhere permanent first, for example `~/Applications`, then open it from there so the login item points at the right place.

On first launch macOS will ask for notification permission and for Local Network access. Allow both. If Local Network access is later denied or revoked, polling and traps will stop working.

## Configuration

On first run the app writes a default config file inside its sandbox container:

```
~/Library/Containers/com.example.chassiswatcher/Data/Library/Application Support/ChassisWatcher/config.json
```

Edit that file. Changes are picked up live, with no restart needed. An existing config file is never rewritten by the app, so new settings added in future versions will not appear in it automatically; the app falls back to defaults for missing keys.

Key settings:

| Key | Meaning |
|---|---|
| `host`, `snmpPort`, `community` | Address and SNMPv1 community of the Areca controller |
| `pollIntervalSeconds` | How often to poll |
| `thresholds.*` | Warn and critical temperatures (C) and minimum fan RPM |
| `healthyRaidStatus`, `healthyVolumeStatus` | String the controller reports when healthy (default `Normal`) |
| `smtp.*` | Mail server, credentials, sender and recipient for email alerts |
| `trapListenPort` | UDP port for incoming traps (default 16200, unprivileged) |
| `repeatAlertIntervalSeconds` | Minimum time between repeat emails for an ongoing condition |
| `logRetentionDays` | How long rotated daily logs are kept (default 90) |

The SMTP password ships as `REPLACE_ME`; set a real one or email alerts will fail (notifications still work). The config file is stored in plain text, so keep its permissions private.

The defaults are generic placeholders. Set `host` to your enclosure's address and `community` to its SNMP community string. Tune thresholds only after logging a day or two of real data, because normal fan speed varies with room temperature.

## Traps

Point the enclosure's SNMP trap destination at this Mac's IP address and `trapListenPort`. Traps with a different community string are ignored and logged.

## Logs

```
~/Library/Containers/com.example.chassiswatcher/Data/Library/Logs/ChassisWatcher/chassiswatcher.log
```

The current day is in `chassiswatcher.log`; past days are renamed to `chassiswatcher-YYYY-MM-DD.log` at local midnight and deleted after `logRetentionDays`.

## Weekly summary (optional)

```sh
./scripts/install_weekly_summary.sh
```

This installs `weekly_summary.py` to `~/Scripts/ChassisWatcher` and a launchd job that emails a summary every Sunday at 08:00 local time. It reads the SMTP settings from the live config file, so there is no separate password to manage. Edit the `Hour` value in the installed plist (`~/Library/LaunchAgents/com.example.chassiswatcher.weeklysummary.plist`) to change the time. The report covers the previous seven days, flags missing days, and checks that the most recent poll is current. It uses the system `/usr/bin/python3` and only the standard library.

## Changing the bundle identifier

The bundle identifier `com.example.chassiswatcher` (in `Info.plist`) determines the sandbox container path. If you change it, update `BUNDLE_ID` in `scripts/weekly_summary.py` and the plist label to match.

## License

MIT. See `LICENSE`.
