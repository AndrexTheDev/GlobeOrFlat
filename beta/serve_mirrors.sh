#!/usr/bin/env bash
# Local mirrors for the sandbox beta run (no external browser egress).
# Production keeps the CDNs — this only feeds the headless test browser.
set -e
(cd /tmp/gof-cesium && python3 -m http.server 8081 --bind 0.0.0.0 >/dev/null 2>&1) &
echo "cesium mirror on :8081"
