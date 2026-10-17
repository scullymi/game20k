#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-only
# Copyright (C) 2026 scullymi
# Builds nextpnr, Apicula and sv-elab (Yosys' slang frontend, as a plugin) for the free toolchain
# from game20k's forks into external/oss-tools/. scripts/build_fpga_oss.sh takes them from there. The forks carry fixes that are not upstream yet,
# each pinned to the commit below.
#   scripts/oss/build_tools.sh
#
# Needs git, cmake, ninja, a C++17 compiler, Boost (program_options, iostreams, thread), Eigen3,
# and the oss-cad-suite under external/ for its Python and Apicula's chip databases (see the head of
# scripts/build_fpga_oss.sh). On macOS: brew install cmake ninja boost eigen
set -euo pipefail
NEXTPNR_REPO=https://github.com/scullymi/nextpnr.git
NEXTPNR_REV=4d79ccb48c60449698ca820694c9832122af95bd
APICULA_REPO=https://github.com/scullymi/apicula.git
APICULA_REV=d707b16f7320399982671f227913bc23529c596c
SV_ELAB_REPO=https://github.com/scullymi/sv-elab.git
SV_ELAB_REV=8b9abd368ea938c3468e886a8c451d2645cf92a8

ROOT=$(cd "$(dirname "$0")/../.." && pwd)
suite=${OSS_CAD_SUITE:-$ROOT/external/oss-cad-suite}
out=$ROOT/external/oss-tools
[ -x "$suite/py3bin/python3" ] || { echo "$suite/py3bin/python3 missing, see the head of scripts/build_fpga_oss.sh" >&2; exit 1; }
mkdir -p "$out"

# checkout <directory> <repository> <commit>
checkout() {
    [ -d "$1/.git" ] || git clone -q --no-checkout "$2" "$1"
    git -C "$1" fetch -q --depth 1 origin "$3"
    git -C "$1" checkout -q --detach FETCH_HEAD
}

echo "== Apicula $APICULA_REV"
checkout "$out/apicula" "$APICULA_REPO" "$APICULA_REV"
# The chip databases come from Gowin's IDE data and are not in the repository. The suite's
# Apicula ships them.
cp "$suite"/lib/python3*/site-packages/apycula/*.msgpack.xz "$out/apicula/apycula/"

echo "== nextpnr $NEXTPNR_REV"
checkout "$out/nextpnr" "$NEXTPNR_REPO" "$NEXTPNR_REV"
git -C "$out/nextpnr" submodule update -q --init --depth 1
cd "$out/nextpnr"
# The output of the chip database generator depends on Python's hash order. With a fixed seed
# every build of the database comes out the same, else it and the bitstreams differ per run.
export PYTHONHASHSEED=0
PYTHONPATH="$out/apicula" cmake -B build -G Ninja -DARCH=himbaechel -DHIMBAECHEL_UARCH=gowin \
    -DHIMBAECHEL_GOWIN_DEVICES=GW2A-18C -DCMAKE_BUILD_TYPE=Release -DBUILD_PYTHON=OFF -DBUILD_GUI=OFF \
    -DPython3_EXECUTABLE="$suite/py3bin/python3" > "$out/nextpnr-cmake.log"
PYTHONPATH="$out/apicula" ninja -C build > "$out/nextpnr-build.log"
echo "$out/nextpnr/build/nextpnr-himbaechel"

echo "== sv-elab $SV_ELAB_REV"
checkout "$out/sv-elab" "$SV_ELAB_REPO" "$SV_ELAB_REV"
git -C "$out/sv-elab" submodule update -q --init --recursive --depth 1
# Only include paths and defines come from yosys-config, the compiler is the local one
cmake -S "$out/sv-elab" -B "$out/sv-elab/build" -G Ninja -DCMAKE_BUILD_TYPE=Release \
    -DYOSYS_CONFIG="$suite/bin/yosys-config" > "$out/sv-elab-cmake.log"
ninja -C "$out/sv-elab/build" yosys-slang > "$out/sv-elab-build.log"
echo "$out/sv-elab/build/slang.so"
