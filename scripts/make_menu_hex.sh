#!/bin/sh
# SPDX-License-Identifier: GPL-3.0-only
# Copyright (C) 2026 scullymi
# Translates the game's menu (fpga/<project>/menu.xml) into the form the FPGA keeps on hand.
# Usage: scripts/make_menu_hex.sh [project folder under fpga/]   (default galaga_hdmi)
#
# The Companion fetches the menu from the FPGA over SPI at startup. There it lives
# gzip-compressed as a hex file that fpga/common/src/mcu/menu_rom.v reads with $readmemh
# (2048 bytes of room). Without this step a change to menu.xml has no effect, the bitstream
# keeps carrying the old menu.
#
# BUT: there is a second menu source, and it wins. If a file /config.xml lies on the SD
# card, the Companion reads that one and leaves the menu in the bitstream untouched
# (FPGA-Companion src/main.c, f_open on sys_get_config_name() BEFORE the fallback to the
# core). Then a change to menu.xml has no effect no matter how often you rebuild and
# flash, and the device shows no sign of it. The only hint goes to the debug UART:
# "Loading XML config from file" versus "Loading XML config from core" (GP0, 921600 baud).
set -e
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
P="${1:-galaga_hdmi}"
D="$ROOT/fpga/$P"
XML="$D/menu.xml"
HEX="$D/menu_xml.hex"
[ -f "$XML" ] || { echo "$XML is missing"; exit 1; }
# Every action a button, list or link names must be defined under <actions>, with or without
# commands. config_get_action() in the Companion resolves an unknown name to NULL, and the
# element then does nothing, without any message on the device. Caught here instead.
python3 -c "
import sys, xml.etree.ElementTree as ET
root = ET.parse(sys.argv[1]).getroot()
defined = {a.get('name') for a in root.iter('action')}
used = {(e.tag, e.get('action')) for e in root.iter() if e.get('action') is not None}
missing = sorted(f'{tag} action=\"{name}\"' for tag, name in used if name not in defined)
if missing:
    print('menu.xml names actions that <actions> does not define: ' + ', '.join(missing))
    sys.exit(1)
" "$XML"
mkdir -p "$D/gen"
# -n leaves out the name and timestamp, otherwise the file changes on every run.
gzip -9 -n -c "$XML" > "$D/gen/menu.xml.gz"
SIZE=$(wc -c < "$D/gen/menu.xml.gz" | tr -d ' ')
if [ "$SIZE" -gt 2048 ]; then
    echo "Menu too large: $SIZE bytes, 2048 fit (fpga/common/src/mcu/menu_rom.v)"; exit 1
fi
python3 -c "
import sys
d=open(sys.argv[1],'rb').read()
open(sys.argv[2],'w').write('\n'.join('%02x'%b for b in d)+'\n')
" "$D/gen/menu.xml.gz" "$HEX"
echo "$HEX written, $SIZE of 2048 bytes"
echo "Takes effect only after build_fpga.sh + flash_fpga.sh + a Pico restart, and only if"
echo "the SD card holds NO /config.xml. That one would take precedence."
