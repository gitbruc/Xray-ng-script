#!/usr/bin/env bash

set -euo pipefail

XRAY_DIR="/usr/local/share/xray"
GEOIP_URL="https://github.com/Loyalsoldier/v2ray-rules-dat/raw/release/geoip.dat"
GEOSITE_URL="https://github.com/Loyalsoldier/v2ray-rules-dat/raw/release/geosite.dat"

mkdir -p "${XRAY_DIR}"
cd "${XRAY_DIR}"

cleanup() {
    rm -f "${XRAY_DIR}/geoip.dat.new" "${XRAY_DIR}/geosite.dat.new"
}
trap cleanup EXIT

curl -fsSL --retry 3 --connect-timeout 15 -o geoip.dat.new "${GEOIP_URL}"
curl -fsSL --retry 3 --connect-timeout 15 -o geosite.dat.new "${GEOSITE_URL}"

if [[ ! -s geoip.dat.new || ! -s geosite.dat.new ]]; then
    echo "Downloaded geodata file is empty." >&2
    exit 1
fi

mv -f geoip.dat.new geoip.dat
mv -f geosite.dat.new geosite.dat

if id -u xray >/dev/null 2>&1 && getent group xray >/dev/null 2>&1; then
    chown -R xray:xray "${XRAY_DIR}"
fi
chmod 755 "${XRAY_DIR}"
chmod 644 "${XRAY_DIR}/geoip.dat" "${XRAY_DIR}/geosite.dat"

if systemctl -q is-active xray; then
    systemctl restart xray
fi
