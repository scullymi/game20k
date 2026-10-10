# Updating a dependency

`scripts/deps_status.py` lists each pinned dependency against its newest upstream release, and for the two forks how many commits their upstream has that they lack. Run it by hand about once a month and before a release. "Watch > Custom > Releases" on the upstream repositories on GitHub sends a mail as well.

It also checks the HDL copied into `fpga/`. For each source its list `VENDORED` holds the commit the copy was taken from and the newest upstream commit already looked at. The report shows what changed in our files after that reviewed commit, and under "Known" what changed between the copy and the reviewed commit, looked at but not taken over. The workflow `upstream.yml` runs this part every Saturday. It fails only on something new, and GitHub mails the failed run. In a fork the weekly run is skipped, because the list holds this repository's review state. "Run workflow" on the Actions tab still starts it by hand.

For now this is a stopgap. The steps after a mail are manual, and a proper solution will follow.

After such a mail:

1. Open the run on GitHub. Its summary lists each changed file with the upstream commits.
2. Look at each commit: does it fix something our games or the platform hit, or does it only serve other games or boards?
3. Decide: take it over now, take it over later (it then stays under "Known"), or leave it.
4. Taking it over: merge the upstream change into our copy by hand, keep our `game20k` changes, build, simulate where there is a testbench, test on the board. Then set the third field of the entry, the copy's commit, and the commit in the source's README and in THIRD-PARTY.md.
5. In every case set the fourth field, the reviewed commit, to the newest upstream commit of the report. The next run is green again.

One update at a time:

1. A short branch, for example `deps/pico-sdk-2.3.1`. For a fork, merge its upstream into branch `game20k`, never rebase.
2. Move the submodule, build the firmware, then `make -C tests/host`, `sh scripts/checks.sh --staged` and `python3 scripts/check_contracts.py`.
3. On the board: start, device key present, ROM known, login and session, achievement list, FTP write protection in hardcore, reset with S1.
4. Merge into `main`. A release with only dependency updates and fixes raises the patch version (0.1.2, 0.1.3), new features raise the minor version.

rcheevos: a new version changes the User-Agent the client sends to RetroAchievements. Once hardcore is approved, update it only on purpose and with the board check.
