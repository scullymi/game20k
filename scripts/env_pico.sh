# SPDX-License-Identifier: GPL-3.0-only
# Copyright (C) 2026 scullymi
# Pico toolchain environment: source scripts/env_pico.sh
ROOT="$(cd "$(dirname "${BASH_SOURCE:-$0}")/.." && pwd)"
export PICO_SDK_PATH="$ROOT/external/pico-sdk"
# TinyUSB from the submodule external/tinyusb (our fork, branch game20k), not the SDK's own
# copy: the Companion needs a newer one plus one changed line, see THIRD-PARTY.md.
export PICO_TINYUSB_PATH="$ROOT/external/tinyusb"
export PICOTOOL_FETCH_FROM_GIT_PATH="$ROOT/external/picotool-src"
# Every SDK release wants its own picotool version (2.3.1 refuses a 2.2.0 picotool). Forcing
# the fetch from git keeps it matched to the SDK the submodule external/pico-sdk pins. The SDK
# caches the source and the build under the path above, so it costs a download once per version.
export PICOTOOL_FORCE_FETCH_FROM_GIT=1

# Locate the Arm toolchain. A preset PICO_TOOLCHAIN_PATH wins over every search path.
#
# The globs are expanded in an sh subshell on purpose. When the shell that sources this file
# is zsh, an unmatched glob aborts with "no matches found" and ends the whole file right here.
# sh passes an unmatched pattern through unchanged and ls reports it on stderr, which the
# 2>/dev/null swallows. The two fixed paths after the subshell need no glob.
if [ -z "$PICO_TOOLCHAIN_PATH" ]; then
  for k in $(sh -c 'ls -d "$HOME"/.pico-sdk/toolchain/arm-gnu-toolchain-* \
                          /Applications/ArmGNUToolchain/*/arm-none-eabi \
                          /opt/arm-gnu-toolchain-* /usr/local/arm-gnu-toolchain-* \
                          2>/dev/null') \
           /usr/lib/arm-none-eabi /usr
  do
    if [ -x "$k/bin/arm-none-eabi-gcc" ]; then PICO_TOOLCHAIN_PATH="$k"; break; fi
  done
fi
# Refuse an empty or wrong path here: exporting it anyway would put "/bin" in front of PATH
# and the build would fail much later with a message unrelated to the cause.
if [ -z "$PICO_TOOLCHAIN_PATH" ] || [ ! -x "$PICO_TOOLCHAIN_PATH/bin/arm-none-eabi-gcc" ]; then
  echo "Arm toolchain not found (arm-none-eabi-gcc)." >&2
  echo "Set PICO_TOOLCHAIN_PATH to the directory that contains bin/arm-none-eabi-gcc," >&2
  echo "or install the Arm GNU Toolchain 14.2 (see README.md)." >&2
  # return works when this file is sourced, exit when it is run as a script
  return 1 2>/dev/null || exit 1
fi
export PICO_TOOLCHAIN_PATH
export PATH="$PICO_TOOLCHAIN_PATH/bin:$PATH"
