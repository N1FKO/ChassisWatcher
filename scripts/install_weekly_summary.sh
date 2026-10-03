#!/bin/zsh
# Installs the weekly summary script and a launchd job (Sundays, 08:00 local time).
set -e
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
LABEL="com.example.chassiswatcher.weeklysummary"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"

mkdir -p "$HOME/Scripts/ChassisWatcher" "$HOME/Library/Logs/ChassisWatcher-WeeklySummary" "$HOME/Library/LaunchAgents"
cp "$SCRIPT_DIR/weekly_summary.py" "$HOME/Scripts/ChassisWatcher/weekly_summary.py"
chmod +x "$HOME/Scripts/ChassisWatcher/weekly_summary.py"
sed "s|__HOME__|$HOME|g" "$SCRIPT_DIR/$LABEL.plist" > "$PLIST"

launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
launchctl bootstrap "gui/$(id -u)" "$PLIST"
echo "Installed. Runs Sundays at 08:00. Test now with:"
echo "  python3 $HOME/Scripts/ChassisWatcher/weekly_summary.py"
