# SPDX-License-Identifier: GPL-3.0-only
# Copyright (C) 2026 scullymi
# Finds the Gowin installation. Sourced by build_fpga.sh and flash_fpga.sh, not run on its
# own. Sets IDE (the folder with bin/gw_sh) and PROGRAMMER (the folder with
# bin/programmer_cli), or ends the calling script with a note.
#
# GOWIN_IDE wins over everything: whoever has the IDE elsewhere sets it and is done. Without
# the variable, the usual locations are searched, macOS as well as Linux.
if [ -n "$GOWIN_IDE" ]; then
  IDE="$GOWIN_IDE"
else
  for k in \
    /Applications/GowinIDE.app/Contents/Resources/Gowin_EDA/IDE \
    "$HOME/Applications/GowinIDE.app/Contents/Resources/Gowin_EDA/IDE" \
    /opt/gowin/IDE /opt/Gowin/IDE "$HOME"/gowin/*/IDE "$HOME"/Gowin/*/IDE \
    /usr/local/gowin/IDE /opt/Gowin_V*/IDE
  do
    [ -x "$k/bin/gw_sh" ] && IDE="$k" && break
  done
fi
if [ -z "$IDE" ] || [ ! -x "$IDE/bin/gw_sh" ]; then
  cat >&2 <<'NOTE'
Gowin EDA not found.

Set GOWIN_IDE to the IDE directory of the installation, that is the folder which contains
bin/gw_sh. Examples:

  macOS   export GOWIN_IDE=/Applications/GowinIDE.app/Contents/Resources/Gowin_EDA/IDE
  Linux   export GOWIN_IDE=/opt/gowin/IDE

The Education edition is sufficient and needs no license file (see README.md).
NOTE
  exit 1
fi
# Every Gowin package puts the Programmer next to the IDE folder.
PROGRAMMER="$(dirname "$IDE")/Programmer"
