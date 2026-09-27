#!/bin/sh
# SPDX-License-Identifier: GPL-3.0-only
# Copyright (C) 2026 scullymi
# The ONE command for the SD card: checks, builds, copies, and says at the end what is missing.
#
# Usage: scripts/make_sdcard.sh [target directory]
#   scripts/make_sdcard.sh                  prepare and check everything in sdcard/
#   scripts/make_sdcard.sh /Volumes/GALAGA  ... and copy it to the card
#
# Sources you provide yourself:
#   roms/galaga.zip      MAME set "galaga" (Namco Rev B), required
#   roms/namco54.zip     explosion sounds, optional
#   sdcard/config.ini    WiFi and RA, created from the template on the first run
#
# What gets produced (all gitignored, all only for the card):
#   sdcard/galaga.rom    from the zips, 38944 bytes
#   sdcard/galaga.ini    starter file with the ROM entry, so the first trip into the OSD is not needed
#
# WHY THE CHECKS RUN HERE AND NOT ON THE DEVICE: the machine has no error channel, the OSD
# shows no errors and the UART is not connected, so a bad card fails silently there. Here
# there is a terminal, so everything is checked here.
set -e
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SD="$ROOT/sdcard"
TARGET="${1:-}"
MISSING=""
NOTES=""

report() { printf '  %-14s %s\n' "$1" "$2"; }

echo "== ROM =="
if [ -f "$ROOT/roms/galaga.zip" ]; then
  # Always rebuild: it costs nothing, and sdcard/galaga.rom is then guaranteed to match roms/.
  if "$ROOT/scripts/make_galaga_rom.sh" "$SD/galaga.rom" >/dev/null; then
    report "galaga.rom" "built, $(wc -c < "$SD/galaga.rom" | tr -d ' ') bytes"
  else
    MISSING="$MISSING galaga.rom(build failed)"
  fi
  if [ -f "$ROOT/roms/namco54.zip" ]; then report "namco54" "included, explosions will sound"
  else report "namco54" "MISSING: roms/namco54.zip. Explosions stay silent, the rest runs"
       NOTES="$NOTES namco54"; fi
elif [ -f "$SD/galaga.rom" ]; then
  report "galaga.rom" "present ($(wc -c < "$SD/galaga.rom" | tr -d ' ') bytes), roms/galaga.zip is missing, not rebuilt"
else
  report "galaga.rom" "MISSING. Provide roms/galaga.zip (MAME set galaga, Namco Rev B, merged set)"
  MISSING="$MISSING galaga.rom"
fi

echo "== config.ini =="
INI="$SD/config.ini"
if [ ! -f "$INI" ]; then
  cp "$SD/config.ini.example" "$INI"; chmod 600 "$INI"
  report "config.ini" "created from the template. Fill it in and run again"
  NOTES="$NOTES config.ini-new"
fi
# Line length limit as in the firmware: it reads config.ini with f_gets into a char
# buffer[64], so a line longer than 62 characters is truncated and, unless the truncated
# head holds a semicolon, dropped. The device shows nothing. Only its debug log prints the
# start of the line. A CR of a CRLF file counts here as it does in the firmware.
n=0; TOO_LONG=0
while IFS= read -r z; do
  n=$((n+1)); [ ${#z} -le 62 ] && continue
  case "$(printf '%.62s' "$z")" in *";"*) ;; *)
    echo "  Line $n ($( printf '%s' "${#z}") characters, no semicolon) would be dropped by the firmware:" >&2
    echo "    $z" >&2; TOO_LONG=1 ;;
  esac
done < "$INI"
if [ "$TOO_LONG" = "1" ]; then
  echo "  Nothing copied. If the WiFi password is too long, only a shorter one helps." >&2
  exit 1
fi
# shellcheck disable=SC1091
. "$ROOT/scripts/credentials.sh"
for pair in "WiFi:WIFI_SSID:WIFI_PASS" "RA:RA_USER:RA_TOKEN"; do
  name=${pair%%:*}; rest=${pair#*:}; a=${rest%%:*}; b=${rest#*:}
  eval "va=\${$a:-}"; eval "vb=\${$b:-}"
  if [ -n "$va" ] && [ -n "$vb" ]; then report "$name" "filled in"
  else report "$name" "not filled in, the game runs without $name anyway"; NOTES="$NOTES $name"; fi
done
report "Lines" "$n, all within the 62-character limit"

echo "== galaga.ini =="
GI="$SD/galaga.ini"
if [ -f "$GI" ]; then
  report "galaga.ini" "present, left untouched"
else
  # Only the ROM entry. The device fills in everything else from the menu defaults, and
  # "Save settings" rewrites the file completely anyway. The path MUST start with /sd:
  # sdc_set_default splits at the last slash into working directory and file name.
  {
    echo "; FPGA Companion settings"
    echo "; Starter file from scripts/make_sdcard.sh. \"Save settings\" rewrites it."
    echo ""
    echo "; image files"
    echo "image0=/sd/galaga.rom"
  } > "$GI"
  report "galaga.ini" "created with image0=/sd/galaga.rom, no trip into the OSD on first start"
fi

if [ -z "$TARGET" ]; then
  echo
  [ -n "$MISSING" ] && echo "Missing:$MISSING" && exit 1
  echo "Everything ready in sdcard/. To copy: scripts/make_sdcard.sh /Volumes/YOUR_CARD"
  exit 0
fi

echo "== Card: $TARGET =="
[ -d "$TARGET" ] || { echo "  Not a directory: $TARGET" >&2; exit 1; }
[ -n "$MISSING" ] && { echo "  Not copied, missing:$MISSING" >&2; exit 1; }
cp "$SD/galaga.rom"  "$TARGET/galaga.rom";  report "galaga.rom"  "copied"
cp "$INI"            "$TARGET/config.ini";  report "config.ini"  "copied"
cp "$SD/README.md"   "$TARGET/README.md";   report "README.md"   "copied"
if [ -f "$TARGET/galaga.ini" ]; then
  # The card carries the settings the device saved. Those win.
  report "galaga.ini" "present on the card, stays: it holds your saved settings"
else
  cp "$GI" "$TARGET/galaga.ini"; report "galaga.ini" "copied (starter file)"
fi
if [ -f "$TARGET/config.xml" ]; then
  echo
  echo "  WARNING: there is a config.xml on the card. It replaces the menu from the"
  echo "  bitstream, permanently and without any notice on the device. If unwanted: delete it."
fi
echo
echo "Done. Eject the card cleanly, otherwise data will be missing."
[ -n "$NOTES" ] && echo "Still open:$NOTES"
exit 0
