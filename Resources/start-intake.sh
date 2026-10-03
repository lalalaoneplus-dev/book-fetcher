#!/usr/bin/env bash
set -euo pipefail

SUPPORT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

while ! /usr/sbin/ipconfig getifaddr en0 >/dev/null 2>&1; do
  /bin/sleep 3
done

exec "$SUPPORT_DIR/BookFetcherServer"
