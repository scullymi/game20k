# SPDX-License-Identifier: MIT
# Copyright (C) 2026 scullymi
"""@file
@brief Five scans of what leaves this machine, run by hand before a commit, from the pre-push
hook and in the CI. No network access.

    g20k.py check --staged [--fork]               the index
    g20k.py check --push [--fork] [REMOTE [URL]]  the outgoing commits, from the stdin lines
                                                  of a pre-push hook
    g20k.py check --ci [--fork] [--base REV]      the tracked files

--fork checks the fork checkout external/FPGA-Companion instead of the game20k tree.

    secrets        PASS, TOKEN and SSID of sdcard/config.ini (or G20K_CONFIG_INI), counted, never
                   shown. Under 8 characters a value counts only as a word in a text file.
                   Skipped only without config.ini (the CI), a key without a value is a finding.
    paths          tracked files that .gitignore excludes, git add -f included, and build
                   output: anything in a folder build, build_* or CMakeFiles
    ra-conditions  RetroAchievements condition chains, conditions such as 0xH0010=5 joined
                   by "_": sets belong to RetroAchievements.
    crlf           files whose line ends changed: a CRLF file stays CRLF
    tests          the host tests (make -C tests/host), game20k tree only, a missing Makefile
                   is a finding. The CI runs them here too, a push that fails there is already
                   public

Each scan prints its sample size, a sample of 0 is a finding. check() returns 1 on a finding.
The scans read bytes, not characters (LC_ALL=C for git and make), so no byte that is not UTF-8
hides a value."""

from __future__ import annotations

import os
import re
import subprocess
import sys
import tempfile
from pathlib import Path

## one condition, "_", and the start of the next one. The interval keeps a stray "0x" in source
## text from pairing with another one far away on the same line
RA_RE = r"0x[ A-Za-z]?[0-9A-Fa-f]+[^_ ]{0,20}_[A-Z]?:?[dpb~]?0x"

## the keys of config.ini whose values must not leave
KEYS = ("PASS", "TOKEN", "SSID")

## the fork checkout inside game20k
FORK = Path("external") / "FPGA-Companion"

## git with paths as they are and without colors
GIT = ["git", "-c", "core.quotepath=off", "-c", "color.ui=never"]

## a build folder, which .gitignore may not name yet
BUILD_DIR = re.compile(rb"((?:.*/)?(?:build|build_[^/]*|CMakeFiles))/")

## the format of the commits a push scan reads, the message included
LOG_FORMAT = "--format=commit %H%n%an <%ae>%n%cn <%ce>%n%B"


def nonzero(oid: str) -> bool:
    """@brief An object name other than git's all zeros, which stands for none."""
    return any(c != "0" for c in oid)


def total(lines: list[bytes]) -> int:
    """@brief The sum of the counts of git grep -c, "[<tip>:]<path>:<count>" per line."""
    return sum(int(line.rsplit(b":", 1)[1]) for line in lines)


def show(name: bytes | str) -> str:
    """@brief A path or name as git printed it, for a message."""
    return name.decode("utf-8", errors="replace") if isinstance(name, bytes) else name


def ini_values(ini: Path) -> dict[str, list[bytes]]:
    """@brief The values of PASS, TOKEN and SSID in config.ini as the firmware reads it: "; comment",
    [SECTION], KEY=value ; comment, in any section. Placeholders (YOUR_...) and empty values
    do not count."""
    values: dict[str, list[bytes]] = {k: [] for k in KEYS}
    for line in ini.read_bytes().split(b"\n"):
        line = line.removesuffix(b"\r")
        if re.match(rb"[ \t]*[;[]", line) or b"=" not in line:
            continue
        key, _, value = line.partition(b"=")
        k = key.upper().replace(b" ", b"").replace(b"\t", b"").decode("ascii", errors="replace")
        v = re.sub(rb";.*", b"", value, flags=re.DOTALL).strip(b" \t")
        if k in values and v and not v.startswith(b"YOUR_"):
            values[k].append(v)
    return values


class Scan:
    """@brief One run of the scans over one tree in one mode."""

    def __init__(self, root: Path, mode: str, fork: bool, base: str, remote: str, tmp: Path) -> None:
        self.root = root
        self.repo = root / FORK if fork else root
        self.what = "fork" if fork else "game20k"
        self.mode = mode
        self.base = base
        self.remote = remote
        self.tmp = tmp
        self.ini = Path(os.environ.get("G20K_CONFIG_INI") or root / "sdcard" / "config.ini")
        self.findings = 0
        self.files = 0
        self.sample = ""
        self.tips: list[str] = []
        self.commits: list[str] = []
        self.text = b""
        self.plain = b""
        self.grep_errors: list[str] = []
        # a hook exports the variables of the repository it runs in, the scans name theirs
        hook_vars = ("GIT_DIR", "GIT_WORK_TREE", "GIT_INDEX_FILE", "GIT_PREFIX")
        self.env = {k: v for k, v in os.environ.items() if k not in hook_vars} | {"LC_ALL": "C"}

    def finding(self, text: str) -> None:
        print(f"FINDING {text}", flush=True)
        self.findings += 1

    def say(self, text: str) -> None:
        print(f"  {text}", flush=True)

    def git(
        self, *args: str, stdin: bytes | None = None, cwd: Path | None = None, quiet: bool = False
    ) -> subprocess.CompletedProcess[bytes]:
        """@brief git in the tree, its output as bytes, errors to the terminal unless quiet."""
        return subprocess.run(
            [*GIT, *args],
            cwd=cwd or self.repo,
            env=self.env,
            input=stdin,
            stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL if quiet else None,
        )

    def ok(self, *args: str) -> bool:
        """@brief Whether a git command succeeds, its output dropped."""
        return self.git(*args, quiet=True).returncode == 0

    def tgrep(self, *args: str) -> list[bytes]:
        """@brief git grep -c over what this mode checks: the index, the tracked files, or the tree
        of each pushed tip. One "[<tip>:]<path>:<count>" line per file with a match."""
        if self.mode == "staged":
            cmd = ["grep", "--cached", "-c", *args]
        elif self.mode == "ci":
            cmd = ["grep", "-c", *args]
        elif self.tips:
            cmd = ["grep", "-c", *args, *self.tips]
        else:
            return []
        p = self.git(*cmd)
        # exit 1 only means no match, anything above is an error that would read as "0 hits"
        if p.returncode > 1:
            self.grep_errors.append(f"git grep {' '.join(args)} exited with {p.returncode}")
        return p.stdout.splitlines()

    def hits(self, values: list[bytes], long: bool) -> int:
        """@brief Lines holding one of the values: anywhere for long values, as a whole word in
        text files for short ones."""
        if not values:
            return 0
        if self.mode == "push":
            lines = (self.text if long else self.plain).split(b"\n")
            if long:
                return sum(1 for line in lines if any(v in line for v in values))
            word = re.compile(
                b"|".join(rb"(?<![A-Za-z0-9_])" + re.escape(v) + rb"(?![A-Za-z0-9_])" for v in values)
            )
            return sum(1 for line in lines if word.search(line))
        # the values go into a file in the private temp folder, never onto a command line
        patterns = self.tmp / ("long" if long else "short")
        patterns.write_bytes(b"".join(v + b"\n" for v in values))
        if long:
            return total(self.tgrep("-a", "-F", "-f", str(patterns)))
        return total(self.tgrep("-I", "-F", "-w", "-f", str(patterns)))

    def outgoing(self, stdin: str) -> bool:
        """@brief The tips and commits of a push from the hook's lines, "<local ref> <local oid>
        <remote ref> <remote oid>" each, and the text they carry. False when nothing goes out."""
        tags = b""
        has_tags = False
        for line in stdin.splitlines():
            lref, loid, _, roid = (line.split(maxsplit=3) + ["", "", "", ""])[:4]
            # a deletion carries nothing
            if not nonzero(loid):
                continue
            tip = self.git("rev-parse", f"{loid}^{{commit}}").stdout.decode().strip()
            if tip:
                self.tips.append(tip)
            if self.git("cat-file", "-t", loid, quiet=True).stdout.strip() == b"tag":
                tags += self.git("cat-file", "tag", loid).stdout
                has_tags = True
            args = [loid, "--not", f"--remotes={self.remote}" if self.remote else "--remotes"]
            if nonzero(roid) and self.ok("cat-file", "-e", f"{roid}^{{commit}}"):
                args.append(roid)
            p = self.git("rev-list", *args)
            self.commits += p.stdout.decode().split()
            if p.returncode != 0:
                self.finding(f"push: cannot list the commits of {lref}")
        self.commits = sorted(set(self.commits))
        if not self.tips:
            self.say("nothing outgoing")
            return False
        # everything the commits carry, messages included: as text for the long values, with
        # binary files left out for the short ones
        if self.commits:
            log = ["log", "--no-walk=unsorted", "--stdin", "-p", "--no-ext-diff", "--no-textconv"]
            log += ["--diff-merges=first-parent", LOG_FORMAT]
            listed = "".join(c + "\n" for c in self.commits).encode()
            self.text = self.git(*log, "--text", stdin=listed).stdout
            self.plain = self.git(*log, stdin=listed).stdout
        self.text += tags
        self.plain += tags
        lines = self.text.count(b"\n")
        self.sample = f"{len(self.commits)} commits, {lines} lines"
        # a ref whose commits are all on the remote already (a renamed branch, a second name): no
        # new text leaves, so an empty text is no blind scan
        if not self.commits and not has_tags:
            self.sample = f"no new commits, all on {self.remote or 'the remote'} already"
        return True

    def check_paths(self) -> None:
        if self.mode == "push":
            names = b"".join(self.git("ls-tree", "-r", "-z", "--name-only", c).stdout for c in self.tips)
        else:
            names = self.git("ls-files", "-z").stdout
        self.files = names.count(b"\0")
        # the user's global ignore file stays out, .gitignore is the only list
        ignored = self.git(
            "-c", "core.excludesFile=/dev/null", "check-ignore", "--no-index", "--stdin", "-z", stdin=names
        ).stdout
        excluded = sorted({p for p in ignored.split(b"\0") if p})
        self.say(f"paths: {self.files} names checked against .gitignore, {len(excluded)} excluded")
        if self.files == 0:
            self.finding("paths: no file to check")
        for p in excluded:
            self.finding(f"paths: {show(p)} is excluded by .gitignore")
        # a build folder the .gitignore does not name yet: one finding per folder, not per file
        builds = sorted({m[1] for n in names.split(b"\0") if (m := BUILD_DIR.match(n))})
        for d in builds:
            self.finding(f"paths: {show(d)}/ is build output and tracked")

    def check_secrets(self) -> None:
        if not self.ini.is_file():
            self.say("secrets: skipped, no config.ini here (the CI has none)")
            return
        values = ini_values(self.ini)
        out = []
        for k in KEYS:
            long = [v for v in values[k] if len(v) >= 8]
            short = [v for v in values[k] if len(v) < 8]
            n = len(set(values[k]))
            h = self.hits(long, True) + self.hits(short, False)
            out.append(f"{k} {h} hits ({n} values)")
            if n == 0:
                self.finding(f"secrets: config.ini has no {k} value, the scan for it would be blind")
            if h:
                self.finding(f"secrets: {h} lines hold a {k} value")
        self.say(f"secrets: {', '.join(out)} in {self.sample}")

    def check_ra(self) -> None:
        # counts per file only, the matching text would be the set
        found = self.tgrep("-I", "-E", RA_RE)
        self.say(f"ra-conditions: {self.files} files, {len(found)} with a condition chain")
        for line in found:
            path, count = line.rsplit(b":", 1)
            self.finding(f"ra-conditions: {show(path)} has {show(count)} lines like a condition chain")

    def eol(self, old: str, new: str | None, changed: set[str]) -> int:
        """@brief Files whose line ends changed from commit old to new (without new: the index)
        into changed, returns how many files it compared. A candidate is a file whose numstat
        changes with --ignore-cr-at-eol. That also takes a newline added at the end of the file,
        so a file counts only when its number of lines with CR changes too."""
        diff = ["diff", "--numstat", "--no-renames", "--no-ext-diff"]
        between = [old, new] if new else ["--cached", old]
        a = self.git(*diff, *between).stdout.splitlines()
        b = self.git(*diff, "--ignore-cr-at-eol", *between).stdout.splitlines()
        stat_b = {f[2]: (f[0], f[1]) for f in (line.split(b"\t", 2) for line in b) if len(f) == 3}
        for line in a:
            f = line.split(b"\t", 2)
            if len(f) == 3 and stat_b.get(f[2]) != (f[0], f[1]):
                path = show(f[2])
                if self.cr_lines(f"{old}:{path}") != self.cr_lines(f"{new or ''}:{path}"):
                    changed.add(path)
        return len(a)

    def cr_lines(self, blob: str) -> int:
        """@brief Lines with a CR in a file of a commit (<commit>:<path>) or the index (:<path>),
        0 when it is not there."""
        return sum(1 for line in self.git("show", blob, quiet=True).stdout.split(b"\n") if b"\r" in line)

    def check_crlf(self) -> None:
        compared = 0
        changed: set[str] = set()
        # --ci compares with --base when given (the CI passes the commit before the push), so a
        # line end change in any commit of the push shows, otherwise with the parent of HEAD. For
        # the fork, the base is the gitlink that the base commit of game20k points at.
        start = ""
        if self.mode == "ci" and nonzero(self.base):
            start = self.base
            if self.what == "fork":
                link = self.git(
                    "rev-parse", "-q", "--verify", f"{self.base}:{FORK.as_posix()}", cwd=self.root
                )
                start = link.stdout.decode().strip()
            if not self.ok("rev-parse", "-q", "--verify", f"{start}^{{commit}}"):
                self.finding(f"crlf: base {self.base} is not in this clone")
                start = ""
        if self.mode == "staged":
            if self.ok("rev-parse", "-q", "--verify", "HEAD"):
                compared += self.eol("HEAD", None, changed)
        elif self.mode == "ci":
            if start:
                compared += self.eol(start, "HEAD", changed)
            elif self.ok("rev-parse", "-q", "--verify", "HEAD^1"):
                compared += self.eol("HEAD^1", "HEAD", changed)
        else:
            for c in self.commits:
                if self.ok("rev-parse", "-q", "--verify", f"{c}^1"):
                    compared += self.eol(f"{c}^1", c, changed)
        crlf = sum(
            1 for line in self.git("ls-files", "--eol").stdout.splitlines() if line.startswith(b"i/crlf")
        )
        self.say(f"crlf: {crlf} CRLF files tracked, {compared} changed files compared")
        if crlf == 0:
            self.finding("crlf: no CRLF file tracked, the scan has nothing to protect")
        for p in sorted(changed):
            self.finding(f"crlf: the line ends of {p} changed")

    def check_tests(self) -> None:
        if self.what != "game20k":
            return
        tests = self.root / "tests" / "host"
        if not (tests / "Makefile").is_file():
            self.finding("tests: tests/host/Makefile is missing")
            return
        try:
            p = subprocess.run(
                ["make", "-C", str(tests)], env=self.env, stdout=subprocess.PIPE, stderr=subprocess.STDOUT
            )
            out, code = p.stdout.decode("utf-8", errors="replace"), p.returncode
        except OSError as e:
            out, code = f"make: {e.strerror}\n", 127
        if code == 0:
            last = re.findall(r"host tests: .*", out)
            self.say(f"tests: {last[-1] if last else ''}")
        else:
            print("\n".join(out.splitlines()[-12:]), flush=True)
            self.finding("tests: the host tests failed (make -C tests/host)")

    def run(self, stdin: str) -> int:
        print(f"checks --{self.mode} ({self.what}):", flush=True)
        if self.mode == "push" and not self.outgoing(stdin):
            return 0
        self.check_paths()
        # the text the secret and RA scans read: lines of the tracked text files, or of the push
        if self.mode != "push":
            self.sample = f"{self.files} files, {total(self.tgrep('-I', '-c', ''))} text lines"
        if self.sample.endswith((" 0 text lines", ", 0 lines")):
            self.finding(f"scan: no text to read ({self.sample})")
        self.check_secrets()
        self.check_ra()
        self.check_crlf()
        self.check_tests()
        for e in self.grep_errors:
            self.finding(f"scan: {e}, the scan result is not valid")
        if self.findings:
            print(f"checks: {self.findings} findings, refused")
            return 1
        print("checks: 0 findings")
        return 0


def check(root: Path, mode: str, fork: bool, base: str, remote: str, stdin: str) -> int:
    """@brief Runs the scans, returns 0 without a finding, 1 with one, 2 when the tree to scan is
    missing. stdin holds the lines of a pre-push hook for --push."""
    tree = root / FORK if fork else root
    if not tree.is_dir():
        print(f"checks: {tree} is missing", file=sys.stderr)
        return 2
    with tempfile.TemporaryDirectory(prefix="g20k-checks.") as tmp:
        return Scan(root, mode, fork, base, remote, Path(tmp)).run(stdin)
