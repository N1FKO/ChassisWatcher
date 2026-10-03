#!/usr/bin/env python3
"""
ChassisWatcher weekly summary.

Reads the previous 7 days of ChassisWatcher's rotated daily logs, computes
high/low/average for every recorded metric (CPU temp, controller temp,
fan1, fan2), flags any non-healthy RAID/volume status seen, counts SNMP
traps received, and does a sanity check that data collection is actually
current (a recent poll exists, and no days are missing from the window).

Emails the result using the same SMTP settings ChassisWatcher itself uses
for alerts, read live from its config.json - this script never stores its
own copy of the password.

Runs weekly via a launchd LaunchAgent (see the accompanying .plist).
"""
import json
import re
import smtplib
import sys
from datetime import datetime, date, timedelta
from email.mime.text import MIMEText
from pathlib import Path

HOME = Path.home()
# Must match CFBundleIdentifier in Info.plist (the App Sandbox container name).
BUNDLE_ID = "com.example.chassiswatcher"
CONTAINER = HOME / "Library" / "Containers" / BUNDLE_ID / "Data" / "Library"
CONFIG_PATH = CONTAINER / "Application Support" / "ChassisWatcher" / "config.json"
LOG_DIR = CONTAINER / "Logs" / "ChassisWatcher"

POLL_RE = re.compile(
    r"^\[(\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2})\] \[INFO\] Poll OK: "
    r"raid=(\S+) volume=(\S+) cpuTemp=(\d+)\u00b0C controllerTemp=(\d+)\u00b0C "
    r"fan1=(\d+) RPM fan2=(\d+) RPM"
)
TRAP_RE = re.compile(r"SNMP TRAP received")

METRICS = ["cpuTemp", "controllerTemp", "fan1", "fan2"]
METRIC_LABELS = {
    "cpuTemp": ("CPU temperature", "\u00b0C"),
    "controllerTemp": ("Controller temperature", "\u00b0C"),
    "fan1": ("Fan 1", "RPM"),
    "fan2": ("Fan 2", "RPM"),
}


def load_config():
    with open(CONFIG_PATH) as f:
        return json.load(f)


def week_window(today=None):
    """7 calendar days ending yesterday, so a Sunday-morning run covers the
    just-finished Sun-Sat week without including today's partial data."""
    today = today or date.today()
    end = today - timedelta(days=1)
    start = end - timedelta(days=6)
    return start, end


def daterange(start, end):
    d = start
    while d <= end:
        yield d
        d += timedelta(days=1)


def dated_log_path(d):
    return LOG_DIR / f"chassiswatcher-{d.isoformat()}.log"


def parse_logs(start, end):
    records = []
    missing_days = []
    for d in daterange(start, end):
        fpath = dated_log_path(d)
        if not fpath.exists():
            missing_days.append(d)
            continue
        text = fpath.read_text(errors="replace")
        for line in text.splitlines():
            m = POLL_RE.match(line)
            if m:
                ts, raid, volume, cpu, ctrl, f1, f2 = m.groups()
                records.append({
                    "ts": ts,
                    "raid": raid,
                    "volume": volume,
                    "cpuTemp": int(cpu),
                    "controllerTemp": int(ctrl),
                    "fan1": int(f1),
                    "fan2": int(f2),
                })
    return records, missing_days


def count_traps(start, end):
    total = 0
    for d in daterange(start, end):
        fpath = dated_log_path(d)
        if fpath.exists():
            total += len(TRAP_RE.findall(fpath.read_text(errors="replace")))
    return total


def most_recent_poll_timestamp():
    """Finds the single most recent Poll OK entry anywhere in the logs
    (checking today's live file plus the two most recent dated files) -
    used for the currency/sanity check, independent of the report window."""
    candidates = [LOG_DIR / "chassiswatcher.log"]
    if LOG_DIR.exists():
        dated = sorted(LOG_DIR.glob("chassiswatcher-*.log"), reverse=True)
        candidates.extend(dated[:2])
    latest = None
    for fpath in candidates:
        if not fpath.exists():
            continue
        text = fpath.read_text(errors="replace")
        for line in reversed(text.splitlines()):
            m = POLL_RE.match(line)
            if m:
                ts = datetime.strptime(m.group(1), "%Y-%m-%d %H:%M:%S")
                if latest is None or ts > latest:
                    latest = ts
                break
    return latest


def summarize_metric(records, key):
    values = [(r[key], r["ts"]) for r in records]
    lo = min(values, key=lambda v: v[0])
    hi = max(values, key=lambda v: v[0])
    avg = sum(v[0] for v in values) / len(values)
    return lo, hi, avg


def build_report(start, end, records, missing_days, config):
    lines = []
    lines.append(f"ChassisWatcher weekly summary: {start.isoformat()} to {end.isoformat()}")
    lines.append("")

    # --- Sanity / currency check ---
    lines.append("== Data sanity check ==")
    now = datetime.now()
    latest = most_recent_poll_timestamp()
    poll_interval = config.get("pollIntervalSeconds", 60)
    if latest is None:
        lines.append("WARNING: could not find ANY poll entries in the logs at all. "
                      "ChassisWatcher may not be running, or the log directory has moved.")
    else:
        age_minutes = (now - latest).total_seconds() / 60
        lines.append(f"Most recent successful poll: {latest.isoformat(sep=' ')} "
                      f"({age_minutes:.0f} minutes ago)")
        if age_minutes * 60 > max(poll_interval * 5, 600):
            lines.append(f"WARNING: that is much longer ago than the {poll_interval:.0f}s poll "
                          f"interval would predict - ChassisWatcher may be stalled or not running.")
        else:
            lines.append("Polling looks current.")

    if missing_days:
        lines.append(f"WARNING: no log file found for {len(missing_days)} day(s) in this window: "
                      + ", ".join(d.isoformat() for d in missing_days))
    else:
        lines.append("Log files present for all 7 days in this window.")

    if not records:
        lines.append("")
        lines.append("No poll data at all was found for this window - nothing further to summarize.")
        return "\n".join(lines)

    expected_per_day = int(86400 / poll_interval) if poll_interval else None
    lines.append(f"Poll records found this week: {len(records)}"
                  + (f" (roughly {expected_per_day}/day expected at the configured "
                     f"{poll_interval:.0f}s interval)" if expected_per_day else ""))
    lines.append("")

    # --- Metric highs/lows ---
    lines.append("== Metric highs and lows ==")
    for key in METRICS:
        (lo_val, lo_ts), (hi_val, hi_ts), avg = summarize_metric(records, key)
        label, unit = METRIC_LABELS[key]
        lines.append(f"{label}: low {lo_val}{unit} (at {lo_ts}), "
                      f"high {hi_val}{unit} (at {hi_ts}), avg {avg:.1f}{unit}")
    lines.append("")

    # --- Health status ---
    healthy_raid = config.get("healthyRaidStatus", "Normal")
    healthy_volume = config.get("healthyVolumeStatus", "Normal")
    bad_raid = [r for r in records if r["raid"] != healthy_raid]
    bad_volume = [r for r in records if r["volume"] != healthy_volume]
    lines.append("== RAID / volume health ==")
    if not bad_raid and not bad_volume:
        lines.append(f'All {len(records)} polls reported raid="{healthy_raid}" '
                      f'and volume="{healthy_volume}" - no issues seen this week.')
    else:
        if bad_raid:
            lines.append(f"WARNING: {len(bad_raid)} poll(s) reported a non-healthy RAID status. "
                          f"First occurrence: {bad_raid[0]['ts']} (raid={bad_raid[0]['raid']})")
        if bad_volume:
            lines.append(f"WARNING: {len(bad_volume)} poll(s) reported a non-healthy volume status. "
                          f"First occurrence: {bad_volume[0]['ts']} (volume={bad_volume[0]['volume']})")
    lines.append("")

    # --- Traps ---
    trap_count = count_traps(start, end)
    lines.append("== SNMP traps ==")
    lines.append(f"{trap_count} trap(s) received this week.")

    return "\n".join(lines)


def send_email(subject, body, smtp_cfg):
    msg = MIMEText(body)
    msg["Subject"] = subject
    msg["From"] = smtp_cfg["fromAddress"]
    msg["To"] = smtp_cfg["toAddress"]

    with smtplib.SMTP(smtp_cfg["host"], smtp_cfg["port"], timeout=30) as server:
        if smtp_cfg.get("useSTARTTLS", True):
            server.starttls()
        server.login(smtp_cfg["username"], smtp_cfg["password"])
        server.sendmail(smtp_cfg["fromAddress"], [smtp_cfg["toAddress"]], msg.as_string())


def main():
    try:
        config = load_config()
    except Exception as e:
        print(f"FATAL: could not read config.json at {CONFIG_PATH}: {e}", file=sys.stderr)
        sys.exit(1)

    start, end = week_window()
    records, missing_days = parse_logs(start, end)
    report = build_report(start, end, records, missing_days, config)

    print(report)  # captured by launchd's StandardOutPath for debugging

    subject = f"[ChassisWatcher] Weekly summary: {start.isoformat()} to {end.isoformat()}"
    try:
        send_email(subject, report, config["smtp"])
    except Exception as e:
        print(f"FATAL: failed to send summary email: {e}", file=sys.stderr)
        sys.exit(1)


if __name__ == "__main__":
    main()
