#!/usr/bin/env bash

set -o pipefail

_APISERVER="${XRAY_API_SERVER:-127.0.0.1:32768}"
_XRAY="${XRAY_BIN:-/usr/local/bin/xray}"

apidata() {
    local -a args=()
    if [[ "${1:-}" == "reset" ]]; then
        args+=("-reset=true")
    fi

    if [[ ! -x "${_XRAY}" ]]; then
        echo "[Error] Xray binary not found or not executable: ${_XRAY}" >&2
        return 1
    fi

    local raw_json=""
    if ! raw_json="$("${_XRAY}" api statsquery --server="${_APISERVER}" "${args[@]}")"; then
        echo "[Error] Failed to query Xray API at ${_APISERVER}. Please ensure Xray is running with stats API enabled." >&2
        return 1
    fi

    if command -v jq >/dev/null 2>&1; then
        printf '%s\n' "${raw_json}" | jq -r '
            (.stat // [])[] |
            select(.name != null) |
            (.name | split(">>>")) as $p |
            select(($p | length) >= 4) |
            "\($p[0]):\($p[1])->\($p[3] | sub("link$"; ""))\t\((.value // 0) | tonumber)"
        '
    else
        printf '%s\n' "${raw_json}" | awk '{
            if (match($1, /"name":/)) {
                f=1; gsub(/^"|link"|,$/, "", $2);
                split($2, p, ">>>");
                printf "%s:%s->%s\t", p[1], p[2], p[4];
            } else if (match($1, /"value":/) && f) {
                f = 0;
                gsub(/"|,/, "", $2);
                printf "%.0f\n", $2;
            } else if (match($0, /}/) && f) {
                f = 0;
                print 0;
            }
        }'
    fi
}

format_table() {
    if command -v numfmt >/dev/null 2>&1; then
        if command -v column >/dev/null 2>&1; then
            numfmt --field=2 --suffix=B --to=iec | column -t
        else
            numfmt --field=2 --suffix=B --to=iec
        fi
    else
        awk -F'\t' '
            function human(x,    u, i) {
                split("B KiB MiB GiB TiB PiB", u, " ");
                i = 1;
                while (x >= 1024 && i < 6) { x /= 1024; i++; }
                return (i == 1) ? sprintf("%.0f%s", x, u[i]) : sprintf("%.1f%s", x, u[i]);
            }
            NF >= 2 { printf "%-32s %s\n", $1, human($2 + 0); }
        '
    fi
}

print_sum() {
    local DATA="$1"
    local PREFIX="$2"
    local SORTED=""
    local SUM=""
    local OUTPUT=""

    SORTED="$(printf '%s\n' "${DATA}" | grep -E "^${PREFIX}:" | sort -r || true)"
    SUM="$(printf '%s\n' "${SORTED}" | awk -F'\t' '
        $1 ~ /->up$/   { us += $2 }
        $1 ~ /->down$/ { ds += $2 }
        END {
            printf "SUM->up:\t%.0f\nSUM->down:\t%.0f\nSUM->TOTAL:\t%.0f\n", us + 0, ds + 0, us + ds + 0;
        }
    ')"

    if [[ -n "${SORTED}" ]]; then
        OUTPUT="${SORTED}"$'\n'"${SUM}"
    else
        OUTPUT="${SUM}"
    fi

    printf '%s\n' "${OUTPUT}" | format_table
}

DATA="$(apidata "${1:-}")" || exit 1
echo "------------Inbound----------"
print_sum "${DATA}" "inbound"
echo "-----------------------------"
echo "------------Outbound----------"
print_sum "${DATA}" "outbound"
echo "-----------------------------"
echo
echo "-------------User------------"
print_sum "${DATA}" "user"
echo "-----------------------------"
