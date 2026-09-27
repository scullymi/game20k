# SPDX-License-Identifier: GPL-3.0-only
# Copyright (C) 2026 scullymi
# Reads the credentials. Other scripts load this file with ". scripts/credentials.sh".
#
# ONE SOURCE: sdcard/config.ini. It is the same file that goes onto the SD card, where the
# machine reads it as /sd/config.ini. Two places for the same value drift apart sooner or
# later, so config.ini is the only place meant to be filled in.
#
# Lookup order, the first real value wins:
#   1. what the environment already holds  (RA_TOKEN=... scripts/make_sdcard.sh)
#   2. sdcard/config.ini                   (the path the documentation describes)
#
# Placeholders from the template (YOUR_...) count as NOT set, so a freshly copied
# config.ini does not pass a placeholder off as a value.
#
# WHY THE FILE REMAINS SENSITIVE DESPITE .gitignore: it lives in the project folder, and on
# the SD card it sits unencrypted on FAT32. .gitignore only prevents an accidental
# "git add". Whoever lends the machine out deletes /sd/config.ini.

CREDENTIAL_KEYS="RA_USER RA_TOKEN WIFI_SSID WIFI_PASS"

# ini_value <file> <SECTION> <KEY>  -> prints the value to stdout, nothing when absent
# Behaves like the firmware's reader: section and key names are case-insensitive, and
# everything after a semicolon is a comment.
ini_value() {
  [ -f "$1" ] || return 0
  awk -v section="$2" -v key="$3" '
    { sub(/\r$/, "") }
    /^[ \t]*\[/ { s=$0; gsub(/[][ \t]/,"",s); cur=toupper(s); next }
    /^[ \t]*;/  { next }
    cur == toupper(section) && index($0,"=") {
      k=substr($0,1,index($0,"=")-1); gsub(/[ \t]/,"",k)
      if (toupper(k) == toupper(key)) {
        v=substr($0,index($0,"=")+1); sub(/;.*/,"",v)
        gsub(/^[ \t]+|[ \t]+$/,"",v)
        print v; exit
      }
    }' "$1"
}

_set_if_empty() {  # _set_if_empty <NAME> <value>: only if NAME is empty and value is real
  eval "_v=\${$1:-}"
  [ -n "$_v" ] && return 0
  case "$2" in ''|YOUR_*) return 0 ;; esac
  eval "$1=\$2"
}

credentials_load() {
  # The calling scripts set ROOT. Relying on "$0" fails as soon as the file is loaded
  # outside a script (under "sh -c", $0 is the shell).
  _root="${ROOT:-$PWD}"
  CREDENTIAL_SOURCE=""

  _ini="$_root/sdcard/config.ini"
  if [ -f "$_ini" ]; then
    _set_if_empty RA_USER   "$(ini_value "$_ini" RA   USER)"
    _set_if_empty RA_TOKEN  "$(ini_value "$_ini" RA   TOKEN)"
    _set_if_empty WIFI_SSID "$(ini_value "$_ini" WIFI SSID)"
    _set_if_empty WIFI_PASS "$(ini_value "$_ini" WIFI PASS)"
    [ -n "${RA_TOKEN:-}${RA_USER:-}" ] && CREDENTIAL_SOURCE="$_ini"
  fi
  return 0
}
credentials_load

credentials_require() {
  for _n in "$@"; do
    eval "_v=\${$_n:-}"
    [ -n "$_v" ] && continue
    echo "$_n is missing." >&2
    echo "Enter it in sdcard/config.ini. If the file does not exist yet:" >&2
    echo "  cp sdcard/config.ini.example sdcard/config.ini && chmod 600 sdcard/config.ini" >&2
    echo "The template explains what each key means." >&2
    exit 1
  done
}
