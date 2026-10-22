#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-only
# Copyright (C) 2026 scullymi
# Downloads the two builds of YosysHQ's oss-cad-suite the free build needs (see the head of
# scripts/build_fpga_oss.sh) for this machine, checks each against its SHA-256 and unpacks them
# under external/ (ignored by git). A suite that is already there with the same date stays.
#   scripts/oss/fetch_suite.sh [main]     main: the first one only, e.g. for Verilator alone
#     external/oss-cad-suite           SUITE_DATE, everything but GHDL (OSS_CAD_SUITE elsewhere)
#     external/oss-cad-suite-20260910  GHDL_DATE, GHDL only (GHDL_SUITE elsewhere)
# The sums are the ones the release page lists,
# https://github.com/YosysHQ/oss-cad-suite-build/releases
# SUITE_DOWNLOADS names a folder that keeps the archives, so that a later run (GitHub Actions'
# cache) unpacks them without a download. Without it they go once unpacked.
set -euo pipefail
SUITE_DATE=20261003
GHDL_DATE=20260910

ROOT=$(cd "$(dirname "$0")/../.." && pwd)
case "$(uname -s)-$(uname -m)" in
    Darwin-arm64)                 platform=darwin-arm64 ;;
    Linux-aarch64 | Linux-arm64)  platform=linux-arm64 ;;
    Linux-x86_64)                 platform=linux-x64 ;;
    *) echo "no oss-cad-suite for $(uname -s) $(uname -m) here" >&2; exit 1 ;;
esac

# sha256 <date>: the release's sum of this platform's archive (macOS' bash 3.2 has no arrays
# by name)
sha256() {
    case "$1-$platform" in
        20261003-darwin-arm64) echo 2ba62757fd7a00429d80c8222090c6c4b3997cd8d8ad57d3badb5dd667537d66 ;;
        20261003-linux-arm64)  echo e5e968bae0ce974c88b41f3de652b5b95e55c6918045b8e65593a648336993be ;;
        20261003-linux-x64)    echo 41b1e1c669efe199ac6e3969b067b84622c365871b4bc09e6b9357ea2f001dcc ;;
        20260910-darwin-arm64) echo 41d6a697316c9892d151c158720fb66d6128655e9a3da526de51626722248bdc ;;
        20260910-linux-arm64)  echo 30e4110c77a27b7b2c6d65ff68f7a5933eb9980d3c7d69b4b5d2f7a45e63ff07 ;;
        20260910-linux-x64)    echo 2c4f7d8b0154d34ac90ed1eb2515d90c9ba138a87293e3e0ad008ddd0dd3f47e ;;
        *) echo "no sum for oss-cad-suite $1 ($platform), see the head of this script" >&2; exit 1 ;;
    esac
}

# fetch <date> <folder>
fetch() {
    local date=$1 dest=$2 sum name tag tmp
    if [ "$(cat "$dest/.suite-date" 2>/dev/null)" = "$date-$platform" ]; then
        echo "$dest: oss-cad-suite $date ($platform) is there"
        return
    fi
    sum=$(sha256 "$date")
    name=oss-cad-suite-$platform-$date.tgz
    tag=${date:0:4}-${date:4:2}-${date:6:2}
    tmp=$(mktemp -d "${TMPDIR:-/tmp}/oss-cad-suite.XXXXXX")
    archive=${SUITE_DOWNLOADS:-$tmp}/$name
    mkdir -p "$(dirname "$archive")"
    echo "== $name"
    if ! echo "$sum  $archive" | shasum -a 256 -c - >/dev/null 2>&1; then
        curl -fsSL --retry 3 -o "$archive" \
            "https://github.com/YosysHQ/oss-cad-suite-build/releases/download/$tag/$name"
    fi
    echo "$sum  $archive" | shasum -a 256 -c -
    # the archive holds one folder, oss-cad-suite/
    tar -xzf "$archive" -C "$tmp"
    rm -rf "$dest"
    mkdir -p "$(dirname "$dest")"
    mv "$tmp/oss-cad-suite" "$dest"
    rm -rf "$tmp"
    echo "$date-$platform" > "$dest/.suite-date"
    echo "$dest: oss-cad-suite $date ($platform)"
}

fetch "$SUITE_DATE" "${OSS_CAD_SUITE:-$ROOT/external/oss-cad-suite}"
[ "${1:-}" = main ] || fetch "$GHDL_DATE" "${GHDL_SUITE:-$ROOT/external/oss-cad-suite-$GHDL_DATE}"
