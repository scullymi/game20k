#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-only
# Copyright (C) 2026 scullymi
# Builds nextpnr, Apicula and sv-elab (Yosys' slang frontend, as a plugin) for the free toolchain
# into external/oss-tools/. scripts/build_fpga_oss.sh takes them from there. nextpnr and Apicula come
# from game20k's forks, which carry fixes that are not upstream yet, sv-elab from upstream. Each is
# pinned to the commit below. Also a Yosys plugin with the fixes in scripts/oss/yosys/.
#   scripts/oss/build_tools.sh
#
# Needs git, cmake, ninja, a C++20 compiler, Boost (program_options, iostreams, thread), and the
# oss-cad-suite under external/ for its Python, Yosys' headers and Apicula's chip databases (see the
# head of scripts/build_fpga_oss.sh). On macOS: brew install cmake ninja boost
# Eigen, which nextpnr's placer solves with, comes from the commit below as well, not from the
# system: Eigen 3.4 and 5 give different placements, so macOS and the CI use the same headers.
set -euo pipefail
NEXTPNR_REPO=https://github.com/scullymi/nextpnr.git
NEXTPNR_REV=354f01802ac131a5a8b81a9d3dbf6ba2b8319d47
APICULA_REPO=https://github.com/scullymi/apicula.git
APICULA_REV=d4eba7de04e7f007fd83e1b8599a269017c36e7f
SV_ELAB_REPO=https://github.com/povik/sv-elab.git
SV_ELAB_REV=dab821430d6403d0de80d08f49714c644cc60ce6
# GitHub mirror of https://gitlab.com/libeigen/eigen
EIGEN_REPO=https://github.com/scullymi/eigen.git
EIGEN_REV=bc3b39870ecb690a623a3f49149a358b95c5781d # 5.0.1
# the commit of the suite's Yosys, which the plugin is built for
YOSYS_REPO=https://github.com/YosysHQ/yosys.git
YOSYS_REV=2f08661ddc20a812488972f57dc0547e08b28597

ROOT=$(cd "$(dirname "$0")/../.." && pwd)
suite=${OSS_CAD_SUITE:-$ROOT/external/oss-cad-suite}
out=$ROOT/external/oss-tools
[ -x "$suite/py3bin/python3" ] || { echo "$suite/py3bin/python3 missing, see the head of scripts/build_fpga_oss.sh" >&2; exit 1; }
mkdir -p "$out"

# checkout <directory> <repository> <commit>
checkout() {
    [ -d "$1/.git" ] || git clone -q --no-checkout "$2" "$1"
    # an existing checkout follows a change of the repository above
    git -C "$1" remote set-url origin "$2"
    git -C "$1" fetch -q --depth 1 origin "$3"
    git -C "$1" checkout -q --detach FETCH_HEAD
}

echo "== Apicula $APICULA_REV"
checkout "$out/apicula" "$APICULA_REPO" "$APICULA_REV"
# The chip databases come from Gowin's IDE data. The suite's Apicula ships them, the fork
# carries its own for the devices it fixes, and those stay.
for db in "$suite"/lib/python3*/site-packages/apycula/*.msgpack.xz; do
    [ -e "$out/apicula/apycula/${db##*/}" ] || cp "$db" "$out/apicula/apycula/"
done

echo "== Eigen $EIGEN_REV"
checkout "$out/eigen" "$EIGEN_REPO" "$EIGEN_REV"
# Installs only the headers and Eigen3Config.cmake, which nextpnr's find_package reads. Build and
# install folders stay outside the checkout, whose file INSTALL would clash with install/ on macOS.
cmake -S "$out/eigen" -B "$out/eigen-build" -G Ninja -DCMAKE_INSTALL_PREFIX="$out/eigen-install" \
    -DBUILD_TESTING=OFF -DEIGEN_BUILD_TESTING=OFF -DEIGEN_BUILD_DOC=OFF -DEIGEN_BUILD_BLAS=OFF \
    -DEIGEN_BUILD_LAPACK=OFF > "$out/eigen-cmake.log"
cmake --install "$out/eigen-build" > "$out/eigen-install.log"

echo "== nextpnr $NEXTPNR_REV"
checkout "$out/nextpnr" "$NEXTPNR_REPO" "$NEXTPNR_REV"
git -C "$out/nextpnr" submodule update -q --init --depth 1
cd "$out/nextpnr"
# The output of the chip database generator depends on Python's hash order. With a fixed seed
# every build of the database comes out the same, else it and the bitstreams differ per run.
export PYTHONHASHSEED=0
# The build regenerates the database only when gowin_arch_gen.py changes, not when Apicula does
rm -f build/himbaechel/uarch/gowin/chipdb-*.bba
PYTHONPATH="$out/apicula" cmake -B build -G Ninja -DARCH=himbaechel -DHIMBAECHEL_UARCH=gowin \
    -DHIMBAECHEL_GOWIN_DEVICES=GW2A-18C -DCMAKE_BUILD_TYPE=Release -DBUILD_PYTHON=OFF -DBUILD_GUI=OFF \
    -DPython3_EXECUTABLE="$suite/py3bin/python3" -DEigen3_DIR="$out/eigen-install/share/eigen3/cmake" \
    > "$out/nextpnr-cmake.log"
PYTHONPATH="$out/apicula" ninja -C build > "$out/nextpnr-build.log"
echo "$out/nextpnr/build/nextpnr-himbaechel"

# slang.so and the Yosys fixes are built against the suite's Yosys, the last step notes which
rm -f "$out/yosys-version.txt"

echo "== sv-elab $SV_ELAB_REV"
checkout "$out/sv-elab" "$SV_ELAB_REPO" "$SV_ELAB_REV"
git -C "$out/sv-elab" submodule update -q --init --recursive --depth 1
# Only include paths and defines come from yosys-config, the compiler is the local one
cmake -S "$out/sv-elab" -B "$out/sv-elab/build" -G Ninja -DCMAKE_BUILD_TYPE=Release \
    -DYOSYS_CONFIG="$suite/bin/yosys-config" > "$out/sv-elab-cmake.log"
ninja -C "$out/sv-elab/build" yosys-slang > "$out/sv-elab-build.log"
echo "$out/sv-elab/build/slang.so"

echo "== Yosys fixes $YOSYS_REV"
# write_xaiger and submod order their output by keys that tie or by heap address, so macOS and
# Linux get different netlists from the same design. The plugin replaces these passes of the
# suite's Yosys with their sources at its commit and the patches in scripts/oss/yosys/.
version=$("$suite/bin/yosys" -V)
case "$version" in
    *"git sha1 ${YOSYS_REV:0:9},"*) ;;
    *) echo "The suite's Yosys is not $YOSYS_REV ($version): set YOSYS_REV and check scripts/oss/yosys/" >&2; exit 1 ;;
esac
# only the files the patches change
files=$(sed -n 's|^+++ b/||p' "$ROOT"/scripts/oss/yosys/*.patch | sort -u)
[ -d "$out/yosys/.git" ] || git clone -q --no-checkout --filter=blob:none "$YOSYS_REPO" "$out/yosys"
git -C "$out/yosys" sparse-checkout set --no-cone $(printf '/%s ' $files)
git -C "$out/yosys" fetch -q --depth 1 --filter=blob:none origin "$YOSYS_REV"
git -C "$out/yosys" checkout -q -f --detach FETCH_HEAD
git -C "$out/yosys" apply "$ROOT"/scripts/oss/yosys/*.patch
# as for sv-elab: flags from yosys-config, the compiler is the local one
c++ $("$suite/bin/yosys-config" --cxxflags) -O2 -shared $([ "$(uname)" = Darwin ] && echo -undefined dynamic_lookup) \
    -o "$out/yosys/fixes.so" $(printf "$out/yosys/%s\n" $files | grep '\.cc$')
echo "$out/yosys/fixes.so"
# scripts/build_fpga_oss.sh loads both plugins only into this Yosys
echo "$version" > "$out/yosys-version.txt"
