#!/usr/bin/env bash
set -euo pipefail

MODE="${1:-run}"
APP_NAME="BookFetcher"
DISPLAY_NAME="Book Fetcher"
BUNDLE_ID="com.prakrinkumar.BookFetcher"
MIN_SYSTEM_VERSION="14.0"

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DIST_DIR="$ROOT_DIR/dist"
APP_BUNDLE="$DIST_DIR/$DISPLAY_NAME.app"
APP_CONTENTS="$APP_BUNDLE/Contents"
APP_MACOS="$APP_CONTENTS/MacOS"
APP_RESOURCES="$APP_CONTENTS/Resources"
APP_BINARY="$APP_MACOS/$APP_NAME"
INFO_PLIST="$APP_CONTENTS/Info.plist"
SERVER_NAME="BookFetcherServer"
SUPPORT_DIR="$HOME/Library/Application Support/Book Fetcher"
SERVER_BINARY="$SUPPORT_DIR/$SERVER_NAME"
TOKEN_FILE="$SUPPORT_DIR/intake-token"
INTAKE_WRAPPER="$SUPPORT_DIR/start-intake.sh"
INTAKE_LABEL="com.prakrinkumar.book-fetcher-intake"
INTAKE_PLIST="$HOME/Library/LaunchAgents/$INTAKE_LABEL.plist"
LOG_DIR="$HOME/Library/Logs/Book Fetcher"
CALIBRE_SUPPORT_DIR="$SUPPORT_DIR/Calibre Server"
CALIBRE_LIBRARY="$SUPPORT_DIR/Calibre Library"
LEGACY_CALIBRE_LIBRARY="$HOME/Documents/Book LAN Library"
CALIBRE_WRAPPER="$CALIBRE_SUPPORT_DIR/start-calibre-lan.sh"
CALIBRE_LABEL="com.prakrinkumar.book-lan-server"
CALIBRE_PLIST="$HOME/Library/LaunchAgents/$CALIBRE_LABEL.plist"
CALIBRE_LOG_DIR="$HOME/Library/Logs/Book LAN Server"
DESKTOP_APP="$HOME/Desktop/$DISPLAY_NAME.app"
INSTALLED_APP="$HOME/Applications/$DISPLAY_NAME.app"
SIGNING_IDENTITY="${SIGN_IDENTITY:--}"
NOTARY_PROFILE="${NOTARY_PROFILE:-}"

pkill -x "$APP_NAME" >/dev/null 2>&1 || true

cd "$ROOT_DIR"
swift build --product "$APP_NAME"
swift build --product "$SERVER_NAME"
BUILD_BINARY="$(swift build --show-bin-path)/$APP_NAME"
BUILD_SERVER="$(swift build --show-bin-path)/$SERVER_NAME"

rm -rf "$APP_BUNDLE"
mkdir -p "$APP_MACOS" "$APP_RESOURCES"
/bin/cp "$BUILD_BINARY" "$APP_BINARY"
chmod +x "$APP_BINARY"
/bin/cp "$ROOT_DIR/Resources/macOS-Info.plist" "$INFO_PLIST"
/bin/cp "$ROOT_DIR/Resources/AppIcon.icns" "$APP_RESOURCES/AppIcon.icns"

/usr/bin/codesign --force --deep --sign "$SIGNING_IDENTITY" "$APP_BUNDLE" >/dev/null

if [[ -n "$NOTARY_PROFILE" && "$SIGNING_IDENTITY" != "-" ]]; then
  NOTARY_ARCHIVE="$DIST_DIR/$APP_NAME-notary.zip"
  /usr/bin/ditto -c -k --keepParent "$APP_BUNDLE" "$NOTARY_ARCHIVE"
  /usr/bin/xcrun notarytool submit "$NOTARY_ARCHIVE" --keychain-profile "$NOTARY_PROFILE" --wait
  /usr/bin/xcrun stapler staple "$APP_BUNDLE"
fi

open_app() {
  /usr/bin/open -n "$APP_BUNDLE"
}

bootstrap_launch_agent() {
  local label="$1"
  local plist="$2"
  local user_domain="gui/$(/usr/bin/id -u)"
  local service_domain="$user_domain/$label"
  local attempt
  local last_output=""

  for ((attempt = 1; attempt <= 10; attempt++)); do
    if last_output=$(/bin/launchctl bootstrap "$user_domain" "$plist" 2>&1); then
      /bin/launchctl enable "$service_domain"
      return 0
    fi
    /bin/launchctl bootout "$service_domain" >/dev/null 2>&1 || true
    /bin/sleep 0.5
  done

  echo "$last_output" >&2
  return 1
}

install_all() {
  /bin/mkdir -p "$SUPPORT_DIR" "$LOG_DIR" "$CALIBRE_SUPPORT_DIR" \
    "$CALIBRE_LOG_DIR" "$HOME/Library/LaunchAgents"
  if [[ ! -s "$TOKEN_FILE" ]]; then
    /usr/bin/openssl rand -hex 24 >"$TOKEN_FILE"
  fi
  /bin/chmod 600 "$TOKEN_FILE"
  /bin/cp "$BUILD_SERVER" "$SERVER_BINARY"
  /bin/cp "$ROOT_DIR/Resources/book-library.html" "$SUPPORT_DIR/book-library.html"
  /bin/cp "$ROOT_DIR/Resources/start-intake.sh" "$INTAKE_WRAPPER"
  /bin/chmod 700 "$SERVER_BINARY" "$INTAKE_WRAPPER"
  /usr/bin/codesign --force --sign "$SIGNING_IDENTITY" "$SERVER_BINARY" >/dev/null

  /bin/cp "$ROOT_DIR/Resources/intake-launch-agent.plist" "$INTAKE_PLIST"
  /usr/libexec/PlistBuddy -c "Set :ProgramArguments:0 $INTAKE_WRAPPER" "$INTAKE_PLIST"
  /usr/libexec/PlistBuddy -c "Set :StandardOutPath $LOG_DIR/intake-stdout.log" "$INTAKE_PLIST"
  /usr/libexec/PlistBuddy -c "Set :StandardErrorPath $LOG_DIR/intake-stderr.log" "$INTAKE_PLIST"
  /bin/chmod 600 "$INTAKE_PLIST"

  /bin/launchctl bootout "gui/$(/usr/bin/id -u)/$INTAKE_LABEL" >/dev/null 2>&1 || true
  /bin/launchctl bootout "gui/$(/usr/bin/id -u)/$CALIBRE_LABEL" >/dev/null 2>&1 || true

  if [[ ! -s "$CALIBRE_LIBRARY/metadata.db" ]]; then
    local source_library=""
    if [[ -s "$LEGACY_CALIBRE_LIBRARY/metadata.db" ]]; then
      source_library="$LEGACY_CALIBRE_LIBRARY"
    else
      local candidate
      for candidate in "$HOME/Documents"/* "$HOME/Library/Application Support"/*/Calibre\ Library; do
        if [[ "$candidate" != "$CALIBRE_LIBRARY" && -s "$candidate/metadata.db" ]]; then
          source_library="$candidate"
          break
        fi
      done
    fi
    if [[ -z "$source_library" ]]; then
      echo "Calibre library not found under Documents or Application Support" >&2
      exit 1
    fi
    /usr/bin/ditto "$source_library" "$CALIBRE_LIBRARY"
  fi

  /bin/cp "$ROOT_DIR/Resources/start-calibre-lan.sh" "$CALIBRE_WRAPPER"
  /usr/bin/sed -i '' \
    -e "s|__LIBRARY_PATH__|$CALIBRE_LIBRARY|g" \
    -e "s|__SERVER_LOG__|$CALIBRE_LOG_DIR/server.log|g" \
    -e "s|__ACCESS_LOG__|$CALIBRE_LOG_DIR/access.log|g" \
    "$CALIBRE_WRAPPER"
  /bin/chmod 700 "$CALIBRE_WRAPPER"

  /bin/cp "$ROOT_DIR/Resources/calibre-launch-agent.plist" "$CALIBRE_PLIST"
  /usr/libexec/PlistBuddy -c "Set :ProgramArguments:0 $CALIBRE_WRAPPER" "$CALIBRE_PLIST"
  /usr/libexec/PlistBuddy -c "Set :StandardOutPath $CALIBRE_LOG_DIR/stdout.log" "$CALIBRE_PLIST"
  /usr/libexec/PlistBuddy -c "Set :StandardErrorPath $CALIBRE_LOG_DIR/stderr.log" "$CALIBRE_PLIST"
  /bin/chmod 600 "$CALIBRE_PLIST"

  bootstrap_launch_agent "$CALIBRE_LABEL" "$CALIBRE_PLIST"

  bootstrap_launch_agent "$INTAKE_LABEL" "$INTAKE_PLIST"

  /bin/mkdir -p "$HOME/Applications"
  /bin/rm -rf "$INSTALLED_APP"
  /usr/bin/ditto "$APP_BUNDLE" "$INSTALLED_APP"
  /usr/bin/xattr -cr "$INSTALLED_APP"
  /usr/bin/codesign --verify --deep "$INSTALLED_APP" >/dev/null

  /bin/rm -rf "$DESKTOP_APP"
  /bin/ln -s "$INSTALLED_APP" "$DESKTOP_APP"
  /usr/bin/open "$INSTALLED_APP"
}

case "$MODE" in
  run)
    open_app
    ;;
  --debug|debug)
    lldb -- "$APP_BINARY"
    ;;
  --logs|logs)
    open_app
    /usr/bin/log stream --info --style compact --predicate "process == \"$APP_NAME\""
    ;;
  --telemetry|telemetry)
    open_app
    /usr/bin/log stream --info --style compact --predicate "subsystem == \"$BUNDLE_ID\""
    ;;
  --verify|verify)
    open_app
    sleep 2
    pgrep -x "$APP_NAME" >/dev/null
    ;;
  --install|install)
    install_all
    ;;
  *)
    echo "usage: $0 [run|--debug|--logs|--telemetry|--verify|--install]" >&2
    exit 2
    ;;
esac
