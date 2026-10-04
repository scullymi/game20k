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
#   roms/<set>.zip       the MAME set of every game you want, e.g. galaga.zip (Namco Rev B);
#                        which zips a game needs says its manifest, fpga/<core>/<set>.manifest
#   roms/namco54.zip     Galaga's explosion sounds, optional
#   sdcard/config.ini    WiFi and RA, created from the template on the first run
#
# What gets produced (all gitignored, all only for the card), per game with a set in roms/:
#   sdcard/<set>.rom     from the zips, checked chip by chip (scripts/make_rom.py)
#   sdcard/<core>.ini    one settings file per core, named as its menu.xml saves it (galaga.ini,
#                        pacman.ini), a starter with the ROM entry, so the first trip into the
#                        OSD is not needed
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

echo "== ROMs =="
# One ROM file per game: every manifest under fpga/ names its set and its zip. A game whose
# zip is missing is left out with a note, the card is still made for the others. Only when
# no game at all is there does the script stop: the screen would stay dark.
SETS=""
PAIRS=""   # core folder:set, for the settings files
for M in $(python3 "$ROOT/scripts/make_rom.py" --list); do
  SET=$(awk '$1 == "set" {print $2; exit}' "$ROOT/$M")
  ZIP=$(awk '$1 == "zip" {print $2; exit}' "$ROOT/$M")
  if [ -f "$ROOT/roms/$ZIP" ]; then
    # Always rebuild: it costs nothing, and sdcard/<set>.rom is then guaranteed to match roms/.
    if OUT=$(python3 "$ROOT/scripts/make_rom.py" "$ROOT/$M" "$SD/$SET.rom" 2>&1); then
      report "$SET.rom" "built, $(wc -c < "$SD/$SET.rom" | tr -d ' ') bytes"
      # the verdict on the file (hardcore possible or not) and the warnings of the build:
      # an optional chip that is missing, an unknown file
      printf '%s\n' "$OUT" | grep -v '^written' | sed 's/^WARNING: //;s/^/                 /'
      printf '%s\n' "$OUT" | grep -q '^WARNING' && NOTES="$NOTES $SET"
      SETS="$SETS $SET"; PAIRS="$PAIRS $(dirname "$M"):$SET"
    else
      printf '%s\n' "$OUT" | sed 's/^/                 /' >&2
      MISSING="$MISSING $SET.rom(build failed)"
    fi
  elif [ -f "$SD/$SET.rom" ]; then
    report "$SET.rom" "present ($(wc -c < "$SD/$SET.rom" | tr -d ' ') bytes), roms/$ZIP is missing, not rebuilt"
    SETS="$SETS $SET"; PAIRS="$PAIRS $(dirname "$M"):$SET"
  else
    report "$SET.rom" "no roms/$ZIP, this game is left out"
  fi
done
[ -n "$SETS" ] || MISSING="$MISSING every-rom(see roms/README.md)"

echo "== config.ini =="
INI="$SD/config.ini"
if [ ! -f "$INI" ]; then
  cp "$SD/config.ini.example" "$INI"; chmod 600 "$INI"
  report "config.ini" "created from the template. Fill it in and run again"
  NOTES="$NOTES config.ini-new"
fi
# Line length limit as in the firmware: it reads config.ini with f_gets into a char
# buffer[128], so a line longer than 126 characters is truncated and, unless the truncated
# head holds a semicolon, dropped. The device shows nothing. Only its debug log prints the
# start of the line. A CR of a CRLF file counts here as it does in the firmware.
n=0; TOO_LONG=0
while IFS= read -r z; do
  n=$((n+1)); [ ${#z} -le 126 ] && continue
  case "$(printf '%.126s' "$z")" in *";"*) ;; *)
    echo "  Line $n ($( printf '%s' "${#z}") characters, no semicolon) would be dropped by the firmware:" >&2
    echo "    $z" >&2; TOO_LONG=1 ;;
  esac
done < "$INI"
if [ "$TOO_LONG" = "1" ]; then
  echo "  Nothing copied. Shorten the line or start its comment earlier." >&2
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
report "Lines" "$n, all within the 126-character limit"

echo "== settings =="
# One settings file per core, under the name its menu.xml loads and saves: the device reads no
# other. It preselects the set named like the file (pacman.rom for pacman.ini), otherwise the
# first set of that core that was built.
INIS=""
for C in $(printf '%s\n' $PAIRS | cut -d: -f1 | sort -u); do
  NAME=$(sed -n 's/.*<save file="\([^"]*\)".*/\1/p' "$ROOT/$C/menu.xml" | head -n 1)
  [ -n "$NAME" ] || { echo "  $C/menu.xml names no settings file" >&2; exit 1; }
  PICK=""
  for P in $PAIRS; do
    [ "${P%%:*}" = "$C" ] || continue
    [ -z "$PICK" ] && PICK=${P#*:}
    [ "${P#*:}.ini" = "$NAME" ] && PICK=${P#*:}
  done
  INIS="$INIS $NAME"
  GI="$SD/$NAME"
  if [ -f "$GI" ]; then
    report "$NAME" "present, left untouched"
  else
    # Only the ROM entry. The device fills in everything else from the menu defaults, and
    # "Save settings" rewrites the file completely anyway. The path MUST start with /sd:
    # sdc_set_default splits at the last slash into working directory and file name.
    {
      echo "; FPGA Companion settings"
      echo "; Starter file from scripts/make_sdcard.sh. \"Save settings\" rewrites it."
      echo ""
      echo "; image files"
      echo "image0=/sd/$PICK.rom"
    } > "$GI"
    report "$NAME" "created with image0=/sd/$PICK.rom, no trip into the OSD on first start"
  fi
done

if [ -z "$TARGET" ]; then
  echo
  [ -n "$MISSING" ] && echo "Missing:$MISSING" && exit 1
  echo "Everything ready in sdcard/. To copy: scripts/make_sdcard.sh /Volumes/YOUR_CARD"
  exit 0
fi

echo "== Card: $TARGET =="
[ -d "$TARGET" ] || { echo "  Not a directory: $TARGET" >&2; exit 1; }
[ -n "$MISSING" ] && { echo "  Not copied, missing:$MISSING" >&2; exit 1; }
cp "$INI"            "$TARGET/config.ini";  report "config.ini"  "copied"
cp "$SD/README.md"   "$TARGET/README.md";   report "README.md"   "copied"
for SET in $SETS; do
  cp "$SD/$SET.rom" "$TARGET/$SET.rom"; report "$SET.rom" "copied"
done
for NAME in $INIS; do
  if [ -f "$TARGET/$NAME" ]; then
    # The card carries the settings the device saved. Those win.
    report "$NAME" "present on the card, stays: it holds your saved settings"
  else
    cp "$SD/$NAME" "$TARGET/$NAME"; report "$NAME" "copied (starter file)"
  fi
done
if [ -f "$TARGET/config.xml" ]; then
  echo
  echo "  WARNING: there is a config.xml on the card. It replaces the menu from the"
  echo "  bitstream, permanently and without any notice on the device. If unwanted: delete it."
fi
echo
echo "Done. Eject the card cleanly, otherwise data will be missing."
[ -n "$NOTES" ] && echo "Still open:$NOTES"
exit 0
