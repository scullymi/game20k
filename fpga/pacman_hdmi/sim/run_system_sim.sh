#!/bin/sh
# SPDX-License-Identifier: GPL-3.0-only
# Copyright (C) 2026 scullymi
# System simulation of the Pac-Man core with a real ROM set (tb_system.vhd, nvc, VHDL-2008),
# its frames compared with MAME's (mame_ref.lua, compare_frames.py).
#
# Usage: [SET=pacman|jrpacman|pacplus|ponpoko] [FRAMES=n] [EVERY=n] [COIN_F=n] [START_F=n] [JOY_F=n] [SEED=n]
#        [MOD_JR=0|1] [PROG=dec|plain] [LAT=0|1] [DUMP_F=n] [SKIP_SIM=1] WORK=<dir> ROMS=<dir>
#        sh fpga/pacman_hdmi/sim/run_system_sim.sh
#   FRAMES   frames from the reset release (default 600), every EVERY-th written (default 5)
#   COIN_F, START_F   coin and start 1, held for 6 frames from that frame (0: attract only)
#   JOY_F    from this frame on the stick moves, a direction held 15 to 60 frames, chosen
#            from SEED (0: no stick)
#   MOD_JR   default 1 for jrpacman, 0 for pacman; PROG=plain loads Jr.'s program without
#            the decryption. Both are for the counter-check, a run that must not match MAME.
#   LAT      0 answers Jr.'s program fetches at once (default 1: the latency model)
#   DUMP_F   writes the priority map of that frame (tb_system.vhd)
#   SKIP_SIM 1 keeps the frames of an earlier run in WORK and only compares again
# pacplus and ponpoko run with MAME's default DIP switches and without inputs (COIN_F,
# START_F and JOY_F are for pacman and jrpacman).
#
# The simulation's frame k is MAME's frame k + d. Without inputs d follows the run (--track).
# With inputs align_inputs.py fits a d per input change and feeds MAME the inputs at those
# frames, because Jr.'s ROM waits make the simulation fall behind MAME where the game is not
# tied to the frame.
#
# ROMS holds pacman.zip, jrpacman.zip, pacplus.zip and ponpoko.zip, MAME's sets. Chips are found by their SHA-1, as
# make_rom.py does, so older chip names work. Jr.'s decryption is imported from
# scripts/make_rom.py, the image is assembled here. Everything generated goes to WORK, ROM
# images included, never into the tree; a run that is compared with another one needs its own
# WORK. The sources are copied to WORK/src first, so a run is not disturbed by edits in the
# tree, and their SHA-256 sums are kept in WORK/src.sha256.
set -e
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../../.." && pwd)"
SET="${SET:-pacman}"
FRAMES="${FRAMES:-600}"
EVERY="${EVERY:-5}"
COIN_F="${COIN_F:-0}"
START_F="${START_F:-0}"
JOY_F="${JOY_F:-0}"
SEED="${SEED:-1}"
PROG="${PROG:-dec}"
LAT="${LAT:-1}"
DUMP_F="${DUMP_F:-0}"
ROMS="${ROMS:-$ROOT/roms}"
W="${WORK:-${TMPDIR:-/tmp}/nvc_system_$SET}"
NVC="${NVC:-nvc}"
# the core's mod inputs, MAME's default DIP switches and the idle inputs of each set
GEN=""
case "$SET" in
  pacman)   MOD_JR="${MOD_JR:-0}"; PORTS="IN0 IN1" ;;
  jrpacman) MOD_JR="${MOD_JR:-1}"; PORTS="P1 P2" ;;
  pacplus)  MOD_JR=0; PORTS="IN0 IN1"; GEN="-gMOD_PLUS=1" ;;
  ponpoko)  MOD_JR=0; PORTS="IN0 IN1"
            GEN="-gMOD_PONP=1 -gDSW1=225 -gDSW2=177 -gIN0_IDLE=224 -gIN1_IDLE=0" ;;
  *) echo "SET is pacman, jrpacman, pacplus or ponpoko" >&2; exit 2 ;;
esac
case "$SET" in pacplus|ponpoko)
  if [ "$COIN_F$START_F$JOY_F" != 000 ]; then echo "$SET runs without inputs" >&2; exit 2; fi ;;
esac
mkdir -p "$W"
mrun() {   # <name> <last>: MAME without inputs
  rm -rf "$W/mame/$1"
  mkdir -p "$W/mame/$1"
  SDL_VIDEODRIVER=dummy SDL_AUDIODRIVER=dummy LAST="$2" PORTS="$PORTS" INPUTS="" OFS=0 \
    timeout 900 mame "$SET" -rompath "$ROMS" -video none -sound none -norotate \
    -keyboardprovider none -mouseprovider none -joystickprovider none -nothrottle -skip_gameinfo \
    -nvram_directory "$W/mame/$1/nvram" -cfg_directory "$W/mame/$1/cfg" \
    -snapshot_directory "$W/mame/$1" -autoboot_script "$HERE/mame_ref.lua" > "$W/mame/$1.log" 2>&1
}
if [ "${SKIP_SIM:-0}" != 1 ]; then
rm -rf "$W/frames" "$W/mame" "$W/lib" "$W/src"
mkdir -p "$W/frames" "$W/mame" "$W/src"

# a snapshot of the sources
cp -R "$HERE/../src/rtl_T80" "$HERE/../src/rtl_pacman" "$W/src/"
cp "$HERE/tb_system.vhd" "$W/src/"
(cd "$W/src" && find . -type f -name "*.vhd" | sort | xargs shasum -a 256 > "$W/src.sha256")

# the download stream, Jr.'s program and the inputs
python3 - "$ROOT" "$ROMS" "$SET" "$PROG" "$W" "$FRAMES" "$COIN_F" "$START_F" "$JOY_F" "$SEED" <<'EOF'
import hashlib, os, random, sys, zipfile
root, roms, game, prog, w = sys.argv[1:6]
frames, coin_f, start_f, joy_f, seed = map(int, sys.argv[6:11])
sys.path.insert(0, os.path.join(root, "scripts"))
from make_rom import jrpacman_decrypt

def chips(zname, wanted):
    """The chips of a set by SHA-1, whatever their names in the zip."""
    z = zipfile.ZipFile(os.path.join(roms, zname))
    by_sha = {}
    for i in z.infolist():
        d = z.read(i)
        by_sha.setdefault(hashlib.sha1(d).hexdigest(), d)
    out = []
    for name, sha in wanted:
        if sha not in by_sha:
            sys.exit("%s: no chip with the SHA-1 of %s" % (zname, name))
        out.append(by_sha[sha])
    return out

dn = []
def section(base, data, mask=None):
    for i, b in enumerate(data):
        dn.append((base | (i & mask) if mask is not None else base + i, b))

if game == "pacman":
    # game_core.sv for Pac-Man: program 0x0000, graphics 0x8000, 7f 0xC300, 4a 0xC100, 1m 0xC000
    c = chips("pacman.zip", [
        ("pacman.6e", "e87e059c5be45753f7e9f33dff851f16d6751181"),
        ("pacman.6f", "674d3a7f00d8be5e38b1fdc208ebef5a92d38329"),
        ("pacman.6h", "8e47e8c2c4d6117d174cdac150392042d3e0a881"),
        ("pacman.6j", "d4a70d56bb01d27d094d73db8667ffb00ca69cb9"),
        ("pacman.5e", "06ef227747a440831c9a3a613b76693d52a2f0a9"),
        ("pacman.5f", "4a937ac02216ea8c96477d4a15522070507fb599"),
        ("82s123.7f", "8d0268dee78e47c712202b0ec4f1f51109b1f2a5"),
        ("82s126.4a", "19097b5f60d1030f8b82d9f1d3a241f93e5c75d6"),
        ("82s126.1m", "bbcec0570aeceb582ff8238a4bc8546a23430081")])
    section(0x0000, b"".join(c[0:4]))
    section(0x8000, b"".join(c[4:6]))
    section(0xC300, c[6], 0x1F)
    section(0xC100, c[7], 0xFF)
    section(0xC000, c[8], 0xFF)
elif game == "pacplus":
    # game_core.sv for Pac-Man Plus: as Pac-Man, the program encrypted (mod_plus decrypts)
    c = chips("pacplus.zip", [
        ("pacplus.6e", "8531c54ca6b0de0ea4ccc34e0e801ba9847e75bc"),
        ("pacplus.6f", "8ba97215bdb75f0e70eb8d3223847efe4dc4fb48"),
        ("pacplus.6h", "4e8613d51a80cf106f883db79685e1e22541da45"),
        ("pacplus.6j", "b956ae5d66683aab74b90469ad36b5bb361d677e"),
        ("pacplus.5e", "57d7d723c7b029e3415801f4ce83469ec97bb8a1"),
        ("pacplus.5f", "9c0699204484be819b77f0b212c792fe9e9fae5d"),
        ("pacplus.7f", "2e43b46ec3b101d1babab87cdaddfa944116ec06"),
        ("pacplus.4a", "cf006536215a7a1d488eebc1d8a2e2a8134ce1a6"),
        ("82s126.1m", "bbcec0570aeceb582ff8238a4bc8546a23430081")])
    section(0x0000, b"".join(c[0:4]))
    section(0x8000, b"".join(c[4:6]))
    section(0xC300, c[6], 0x1F)
    section(0xC100, c[7], 0xFF)
    section(0xC000, c[8], 0xFF)
elif game == "ponpoko":
    # game_core.sv for Ponpoko: program 0x0000, second bank 0x4000 (CPU 0x8000), graphics
    # 0x8000, Pac-Man's PROMs
    c = chips("ponpoko.zip", [
        ("ppokoj1.bin", "d9e3186dcd4eb94d02bd24ad56030b248721537f"),
        ("ppokoj2.bin", "4b8bd13e58040c30ca032b54fb47d889677e8c6f"),
        ("ppokoj3.bin", "1a57767557c13fa3d08e4451fb9fb1f7219b26ef"),
        ("ppokoj4.bin", "d4835ee97c9b3c63504d8b576a11f0a3a97057ec"),
        ("ppoko5.bin", "b54299b00573fbd6d3278586df0c12c09235615d"),
        ("ppoko6.bin", "ab3fb9c8846effdcea0569d08a84c5fa19057a8f"),
        ("ppoko7.bin", "577c79c016be26a9fc7895cef0f30bf3f0b15097"),
        ("ppokoj8.bin", "9b86ae34aaefa2813d29a4f7b24cee40eadcc6a1"),
        ("ppoko9.bin", "f1229e804eb15827b71f0e769a8c9e496c6d1de7"),
        ("ppoko10.bin", "1b58ad1c2cc2d12f4e492fdd665b726d50c80364"),
        ("82s123.7f", "8d0268dee78e47c712202b0ec4f1f51109b1f2a5"),
        ("82s126.4a", "19097b5f60d1030f8b82d9f1d3a241f93e5c75d6"),
        ("82s126.1m", "bbcec0570aeceb582ff8238a4bc8546a23430081")])
    section(0x0000, b"".join(c[0:4]))
    section(0x4000, b"".join(c[4:8]))
    section(0x8000, b"".join(c[8:10]))
    section(0xC300, c[10], 0x1F)
    section(0xC100, c[11], 0xFF)
    section(0xC000, c[12], 0xFF)
else:
    # game_core.sv for Jr. Pac-Man: graphics 0xA000, 9e 0xE000, 9f 0xE100, 9p 0xE200,
    # 7p 0xE300; the program goes through jr_rom_*
    c = chips("jrpacman.zip", [
        ("8d", "5ea34621213c649ca2848ab31aab2cbe751723d4"),
        ("8e", "8294e9e79f8fd19a419431fa690e6ac4a1302f58"),
        ("8h", "b84b34560b9aae18b24274712b052283faa01730"),
        ("8j", "07d912a61824323c8fc1b8bd0da89172d4f70b91"),
        ("8k", "18bd4d5381656120e4242811006c20776774de4d"),
        ("2c", "37fe3176b0d125b7d629e108e7ebdc1196e4a132"),
        ("2e", "f00a488958ea0438642d345693787bdf771219ad"),
        ("9e", "d9aa2dc442e9ac36cf3c346b9fb1aa745eaf3cb8"),
        ("9f", "7561f8ccab2af85c111af6a02af6986eb67503e5"),
        ("9p", "62cf15513934d34641433c891a7f73bef82e2fb1"),
        ("7p", "bbcec0570aeceb582ff8238a4bc8546a23430081")])
    section(0xA000, b"".join(c[5:7]))
    section(0xE000, c[7], 0xFF)
    section(0xE100, c[8], 0xFF)
    section(0xE200, c[9], 0xFF)
    section(0xE300, c[10], 0xFF)
    p = b"".join(c[0:5])
    if prog == "dec":
        p = jrpacman_decrypt(p)
    with open(os.path.join(w, "prog.txt"), "w") as f:
        f.writelines("%02X\n" % b for b in p)
    print("program %s, SHA-1 %s" % (prog, hashlib.sha1(p).hexdigest()))
with open(os.path.join(w, "dn.txt"), "w") as f:
    f.writelines("%04X %02X\n" % (a, d) for a, d in dn)
print("download %d writes" % len(dn))

# inputs: in0 bit 0 up, 1 left, 2 right, 3 down, 5 coin; in1 bit 5 start 1; active low
UP, LEFT, RIGHT, DOWN = 0x01, 0x02, 0x04, 0x08
lines = []   # (frame, port, mask, pressed)
if coin_f: lines += [(coin_f, 0, 0x20, True), (coin_f + 6, 0, 0x20, False)]
if start_f: lines += [(start_f, 1, 0x20, True), (start_f + 6, 1, 0x20, False)]
if joy_f:
    rng, f, prev = random.Random(seed), joy_f, None
    while f < frames:
        d = rng.choice([x for x in (UP, LEFT, RIGHT, DOWN) if x != prev])
        hold = rng.randint(15, 60)
        lines += [(f, 0, d, True), (min(f + hold, frames), 0, d, False)]
        f, prev = f + hold, d
cur = [0xFF, 0xFF]
out = []
for f in sorted(set(l[0] for l in lines)):
    # releases first, then presses, both of the same frame
    for fr, port, mask, on in sorted((l for l in lines if l[0] == f), key=lambda l: l[3]):
        cur[port] = (cur[port] & ~mask) if on else (cur[port] | mask)
    out.append("%d %02X %02X\n" % (f, cur[0], cur[1]))
if out:
    open(os.path.join(w, "inputs.txt"), "w").writelines(out)
    print("inputs %d changes, first at frame %s" % (len(out), out[0].split()[0]))
elif os.path.exists(os.path.join(w, "inputs.txt")):
    os.remove(os.path.join(w, "inputs.txt"))
EOF

# MAME without inputs while the simulation runs
mrun attract "$((FRAMES + 40))" &
mame_pid=$!

# the simulation
t0=$(date +%s)
mkdir -p "$W/lib"
S="$W/src"
"$NVC" --std=2008 --ieee-warnings=off --work=work:"$W/lib/work" -a \
  "$S/rtl_T80/T80_Pack.vhd" "$S/rtl_T80/T80_ALU.vhd" "$S/rtl_T80/T80_MCode.vhd" \
  "$S/rtl_T80/T80_Reg.vhd" "$S/rtl_T80/T80.vhd" "$S/rtl_T80/T80sed.vhd" \
  "$S/rtl_pacman/g20k_dpram.vhd" "$S/rtl_pacman/sn76489_top.vhd" "$S/rtl_pacman/ym2149.vhd" \
  "$S/rtl_pacman/pacman_vram_addr.vhd" "$S/rtl_pacman/pacman_video.vhd" \
  "$S/rtl_pacman/pacman_audio.vhd" "$S/rtl_pacman/pacman_rom_descrambler.vhd" \
  "$S/rtl_pacman/pacman.vhd" "$S/tb_system.vhd" > "$W/build.log" 2>&1 || { cat "$W/build.log"; exit 1; }
"$NVC" --std=2008 --ieee-warnings=off --work=work:"$W/lib/work" -e tb_system \
  -gMOD_JR="$MOD_JR" -gFRAMES="$FRAMES" -gEVERY="$EVERY" -gSEED="$SEED" -gLAT="$LAT" \
  -gDUMP_F="$DUMP_F" -gDIR="$W" $GEN \
  >> "$W/build.log" 2>&1 || { cat "$W/build.log"; exit 1; }
t1=$(date +%s)
"$NVC" --ieee-warnings=off --work=work:"$W/lib/work" -r tb_system --exit-severity=failure > "$W/sim.log" 2>&1 || {
  tail -20 "$W/sim.log"; kill "$mame_pid" 2>/dev/null; exit 1; }
t2=$(date +%s)
echo "build $((t1 - t0)) s, simulation $((t2 - t1)) s for $FRAMES frames" | tee -a "$W/sim.log"
grep -E "waits after frame $FRAMES|download|program|END" "$W/sim.log" || true
wait "$mame_pid"
fi

# the comparison: one offset without inputs, one per input change with them
if [ -f "$W/inputs.txt" ]; then
  SET="$SET" PORTS="$PORTS" ROMS="$ROMS" LUA="$HERE/mame_ref.lua" \
    python3 "$HERE/align_inputs.py" "$W/frames" "$W/inputs.txt" "$W/mame/attract" "$W/mame" \
    "$((FRAMES + 40))" | tee "$W/align.log"
  python3 "$HERE/compare_frames.py" "$W/frames" "$W/mame/play" --offsets "$W/mame/offsets.txt" \
    --window 16 --sheet "$W/compare.png" | tee "$W/compare.log"
else
  python3 "$HERE/compare_frames.py" "$W/frames" "$W/mame/attract" --track 1 --window 16 \
    --sheet "$W/compare.png" | tee "$W/compare.log"
fi
