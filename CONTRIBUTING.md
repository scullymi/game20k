# Contributing

Thanks for your interest in game20k. This is a small hobby project, so replies may take a few
days.

## Issues

Report bugs and suggest features through the issue forms. For a bug, the firmware version from
the menu (`Status`, `Version`) and the serial log help most.

For anything larger than a small fix, please open an issue first, so we can agree on the
approach before you put work into it.

## Pull requests

- Build and test as described in [docs/BUILD.md](docs/BUILD.md), and test on the device if your
  change affects it.
- Run `scripts/checks.sh --staged` before you commit. It runs the host tests and checks for
  files that must never be committed.
- Keep a pull request to one topic, with a short commit message in English.
- Code, comments and documentation are in English. Comments describe the code as it is, not its
  history.
- Firmware changes belong in [scullymi/FPGA-Companion](https://github.com/scullymi/FPGA-Companion)
  (branch `game20k`), which this repository includes as a submodule.

## Never commit

- ROM data of any kind, including files or tables generated from ROMs.
- RetroAchievements achievement sets or their conditions. They belong to RetroAchievements.
- Credentials: WiFi passwords, RetroAchievements tokens, your `config.ini`.

## Licence

By contributing, you agree that your contribution is licensed under the licence of the files
you change: GPL-3.0-only in this repository, Apache-2.0 for the files we add to the
FPGA-Companion fork. See [THIRD-PARTY.md](THIRD-PARTY.md) for third-party code.

## RetroAchievements

The device identifies itself to RetroAchievements as game20k. Never change the User-Agent to
that of another emulator, and keep hardcore protections intact. RetroAchievements approves each
client by hand, and a single violation can get a client banned.
