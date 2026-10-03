#!/usr/bin/env bash
set -euo pipefail

SUPPORT_DIR="$HOME/Library/Application Support/Book Fetcher"
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
INTAKE_LABEL="$(/usr/libexec/PlistBuddy -c 'Print :Label' "$ROOT_DIR/Resources/intake-launch-agent.plist")"
CALIBRE_LABEL="$(/usr/libexec/PlistBuddy -c 'Print :Label' "$ROOT_DIR/Resources/calibre-launch-agent.plist")"
USER_DOMAIN="gui/$(id -u)"

for label in "$INTAKE_LABEL" "$CALIBRE_LABEL"; do
  /bin/launchctl bootout "$USER_DOMAIN/$label" >/dev/null 2>&1 || true
  rm -f "$HOME/Library/LaunchAgents/$label.plist"
done

rm -f "$SUPPORT_DIR/BookFetcherServer" \
  "$SUPPORT_DIR/book-library.html" \
  "$SUPPORT_DIR/start-intake.sh" \
  "$SUPPORT_DIR/Calibre Server/start-calibre-lan.sh"
rmdir "$SUPPORT_DIR/Calibre Server" 2>/dev/null || true

printf 'Kept the Calibre library and pairing token in %s\n' "$SUPPORT_DIR"
printf 'Kept downloads in %s\n' "$HOME/Downloads/Book Fetcher"
