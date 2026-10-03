# Security policy

## Reporting a vulnerability

Please do not use public issues for security problems. Use GitHub's private reporting instead:
open the **Security** tab of this repository and choose **Report a vulnerability**.

Useful reports include, for example:

- a way to read or change the SD card over the network beyond what
  [the README](README.md#known-issues) already lists
- a way to leak the WiFi password or the RetroAchievements token
- a way to fake hardcore unlocks or get around the hardcore checks

This is a hobby project, so a reply may take a few days. Fixes go into the next release.

## Supported versions

Only the latest release receives fixes.

## Known limitations

The FTP server accepts any login, and telnet shows the debug log to anyone on the local
network. Both are listed under [Known issues](README.md#known-issues) and need no report.
