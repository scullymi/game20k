# Updating a dependency

`scripts/deps_status.py` lists each pinned dependency against its newest upstream release, and for the FPGA-Companion fork how many upstream commits it lacks. Run it by hand about once a month and before a release. "Watch > Custom > Releases" on the upstream repositories on GitHub sends a mail as well.

It also checks the HDL copied into `fpga/`. For each source its list `VENDORED` holds the commit the copy was taken from and the newest upstream commit already looked at. The report shows what changed in our files after that reviewed commit, and under "Known" what changed between the copy and the reviewed commit, looked at and mostly not taken over. A single change that was taken over is named in the README of the folder it went into. The workflow `upstream.yml` runs this part every Saturday. It fails only on something new, and GitHub mails the failed run. In a fork the weekly run is skipped, because the list holds this repository's review state. "Run workflow" on the Actions tab still starts it by hand.

After such a mail:

1. Open the run on GitHub. Its summary lists each changed file with the upstream commits.
2. Look at each commit: does it fix something our games or the platform hit, or does it only serve other games or boards?
3. Decide: take it over now, take it over later (it then stays under "Known"), or leave it.
4. Taking it over: merge the upstream change into our copy by hand, keep our `game20k` changes, build, simulate where there is a testbench, test on the board. Then set the third field of the entry, the copy's commit, and the commit in the source's README and in THIRD-PARTY.md.
5. In every case set the fourth field, the reviewed commit, to the newest upstream commit of the report. The next run is green again.

One update at a time:

1. A short branch, for example `deps/pico-sdk-2.3.1`. For a fork, merge its upstream into branch `game20k`, never rebase.
2. Move the submodule, build the firmware, then `python3 g20k.py test`, `python3 g20k.py check --staged` and `python3 scripts/check_contracts.py`.
3. On the board: start, device key present, ROM known, login and session, achievement list, FTP write protection in hardcore, reset with S1.
4. Merge into `main`. A release with only dependency updates and fixes raises the patch version (the third number), new features raise the minor version.

rcheevos: a new version changes the User-Agent the client sends to RetroAchievements. Once hardcore is approved, update it only on purpose and with the board check.

## The tools of the build

[tools.toml](../tools.toml) pins every program of the build, in two kinds of entries.

`[download.<name>]` is a released archive for each kind of machine (`darwin-arm64`,
`linux-x64`, `windows-x64`) with its SHA-256 from the release page. To update one, change
`version`, `release` and each `url` and `sha256`, run `python3 g20k.py tools fetch <name>` and
build what uses it. A new suite also changes the key of the forks, see below.

`[source.<name>]` is a repository at one commit: game20k's forks of Yosys, nextpnr and
Apicula, and Eigen, which nextpnr's placer needs. To update a fork, merge its upstream into its
branch `game20k`, never rebase, push it and set the new commit here.

The forks come prebuilt. Their key (`python3 g20k.py tools key`) is made of the commits of every
`[source.<name>]`, the suite version and the text of `tools/engine/forks.py`. When the bitstream workflow first
runs with a new key, `.github/workflows/forks.yml` builds the forks on each kind of machine and
publishes them as the release `forks-<key>` of the repository that `[prebuilt]` names. Until that release exists,
`python3 g20k.py tools build-forks` builds them on your machine, see
[BUILD.md](BUILD.md#building-the-forks-yourself).

A new tool can change the bitstreams. Build every core (`python3 g20k.py release --dev`, which
stops on a core that misses its clock) and test every game on the board before a release.
