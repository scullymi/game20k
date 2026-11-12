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
- Run the checks below before you commit and before you push.
- Keep a pull request to one topic, with a short commit message in English.
- Code, comments and documentation are in English. Comments describe the code as it is, not its
  history.
- A new core or board: [docs/cores.md](docs/cores.md).
- Firmware changes belong in [scullymi/FPGA-Companion](https://github.com/scullymi/FPGA-Companion)
  (branch `game20k`), which this repository includes as a submodule.

## Checks before a commit and a push

`g20k.py check` scans what leaves your machine: secrets, ignored files and build output,
RetroAchievements conditions, changed line ends, and the host tests. Before a commit it checks
the index, with `--fork` that of the fork checkout:

```sh
python3 g20k.py check --staged
python3 g20k.py check --staged --fork
```

Before a push, run what the checks job of the CI runs:

```sh
python3 g20k.py check --ci
python3 g20k.py check --ci --fork
python3 scripts/check_contracts.py
python3 -m unittest discover -s tools/engine/tests -t .
```

and `ruff check`, `ruff format --check`, `mypy` and
`clang-format --dry-run -Werror external/FPGA-Companion/src/game20k/*.[ch]` in the versions of
the `dev` group in [pyproject.toml](pyproject.toml). The CI also runs the simulations
(`python3 g20k.py sim`) and builds the firmware and the bitstreams, see [docs/BUILD.md](docs/BUILD.md).

The secrets scan looks for the values in `sdcard/config.ini`. If your real file lives elsewhere,
point `G20K_CONFIG_INI` to it. A pre-push hook runs the scan on the outgoing commits. Save this
as `.git/hooks/pre-push` and make it executable:

```sh
#!/bin/sh
exec python3 g20k.py check --push "$@"
```

## Never commit

- ROM data of any kind, including files or tables generated from ROMs.
- RetroAchievements achievement sets or their conditions. They belong to RetroAchievements.
- Credentials: Wi-Fi passwords, RetroAchievements tokens, your `config.ini`.

## License

By contributing, you agree that your contribution is licensed under the license of the files
you change: GPL-3.0-only in this repository, Apache-2.0 for the files we add to the
FPGA-Companion fork. See [THIRD-PARTY.md](THIRD-PARTY.md) for third-party code.

## RetroAchievements

The device identifies itself to RetroAchievements as game20k. Never change the User-Agent to
that of another emulator, and keep hardcore protections intact. RetroAchievements approves each
client by hand, and a single violation can get a client banned.
