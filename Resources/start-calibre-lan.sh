#!/usr/bin/env bash
set -euo pipefail

while ! /usr/sbin/ipconfig getifaddr en0 >/dev/null 2>&1; do
  /bin/sleep 3
done

lan_ip="$(/usr/sbin/ipconfig getifaddr en0)"
case "$lan_ip" in
  10.*|192.168.*|172.1[6-9].*|172.2[0-9].*|172.3[01].*) ;;
  *)
    printf '%s\n' "Book LAN Server refused to start without a private en0 IPv4 address." >&2
    exit 75
    ;;
esac

exec /Applications/calibre.app/Contents/MacOS/calibre-server \
  "__LIBRARY_PATH__" \
  --port=8080 \
  --listen-on="$lan_ip" \
  --disable-fallback-to-detected-interface \
  --disable-auth \
  --disable-local-write \
  --enable-use-bonjour \
  --shutdown-timeout=5 \
  --max-log-size=5 \
  --log="__SERVER_LOG__" \
  --access-log="__ACCESS_LOG__"
