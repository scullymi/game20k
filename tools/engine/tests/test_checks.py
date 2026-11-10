# SPDX-License-Identifier: MIT
# Copyright (C) 2026 scullymi
"""@file
@brief Tests for the scans of g20k.py check: each one finds a crafted bad input in a throwaway
repository and stays quiet on a clean one.

The repositories get game20k's .gitignore and a stand-in tests/host/Makefile. Their commits
carry a Saturday date and are never signed, so no global hook refuses them and no signing
reaches a key agent. No push happens, refs/remotes/origin/main marks what the remote has. The
credentials are made up."""

import io
import os
import shutil
import subprocess
import tempfile
import unittest
from contextlib import redirect_stdout
from pathlib import Path
from unittest import mock

from tools.engine import checks

## the game20k tree, for its .gitignore
ROOT = Path(__file__).resolve().parents[3]

## a Saturday
DATE = "2026-09-26T12:00:00+0200"

FAKE_TOKEN = "FAKETOKEN0123456"
FAKE_PASS = "FakePass-0123456789"
## under 8 characters: counted as a whole word in text files only
FAKE_SSID = "FakeNet"
FAKE_INI = (
    f"[WIFI]\nSSID={FAKE_SSID}\nPASS={FAKE_PASS} ; home\n\n[RA]\nUSER=someone\nTOKEN={FAKE_TOKEN}\n;TOKEN=x\n"
)

## joined at run time: the chain in this file would be a finding of the scan itself
RA_CHAIN = "_".join(["0xH0010=5", "0xH0011=1", "d0xH0012!=0xH0012"])

CRLF_TEXT = b"entity x is\r\nend x;\r\n"

## a stand-in for the host tests: passes unless FAIL is set
MAKEFILE = (
    "all:\n"
    '\t@if [ -n "$(FAIL)" ]; then echo broken; exit 1; fi\n'
    "\t@echo 'host tests: 1 of 1 binaries passed, 3 tests, 0 failures, 0 ignored'\n"
)


def git_env() -> dict[str, str]:
    """@brief Environment for throwaway git: fixed identity and date, no signing."""
    env = {k: v for k, v in os.environ.items() if not k.startswith("GIT_")}
    env.update(
        {
            "GIT_AUTHOR_DATE": DATE,
            "GIT_COMMITTER_DATE": DATE,
            "GIT_AUTHOR_NAME": "test",
            "GIT_AUTHOR_EMAIL": "test@example.invalid",
            "GIT_COMMITTER_NAME": "test",
            "GIT_COMMITTER_EMAIL": "test@example.invalid",
            "GIT_CONFIG_COUNT": "4",
            "GIT_CONFIG_KEY_0": "gpg.ssh.program",
            "GIT_CONFIG_VALUE_0": "false",
            "GIT_CONFIG_KEY_1": "commit.gpgsign",
            "GIT_CONFIG_VALUE_1": "false",
            "GIT_CONFIG_KEY_2": "core.autocrlf",
            "GIT_CONFIG_VALUE_2": "false",
            "GIT_CONFIG_KEY_3": "tag.gpgsign",
            "GIT_CONFIG_VALUE_3": "false",
        }
    )
    return env


class Repo:
    """@brief A throwaway repository with game20k's .gitignore and a stand-in host test."""

    def __init__(self, path: Path) -> None:
        self.path = path
        path.mkdir(parents=True)
        self.git("init", "-q")
        self.git("symbolic-ref", "HEAD", "refs/heads/main")
        shutil.copy(ROOT / ".gitignore", path / ".gitignore")
        self.write("tests/host/Makefile", MAKEFILE)

    def git(self, *args: str, stdin: str | None = None) -> str:
        r = subprocess.run(
            ["git", *args], cwd=self.path, env=git_env(), input=stdin, capture_output=True, text=True
        )
        if r.returncode:
            raise RuntimeError(f"git {' '.join(args)}: {r.stderr}")
        return r.stdout.strip()

    def write(self, rel: str, data: str | bytes) -> None:
        p = self.path / rel
        p.parent.mkdir(parents=True, exist_ok=True)
        p.write_bytes(data if isinstance(data, bytes) else data.encode())

    def commit(self, msg: str = "change") -> str:
        self.git("add", "-A")
        self.git("commit", "-q", "--no-gpg-sign", "--allow-empty", "-m", msg)
        return self.git("rev-parse", "HEAD")


@unittest.skipIf(os.name == "nt", "the scans run in the hooks of a Mac or Linux machine and in the Linux CI")
class Base(unittest.TestCase):
    def setUp(self) -> None:
        self.tmp = tempfile.TemporaryDirectory()
        self.ini = Path(self.tmp.name) / "config.ini"
        self.ini.write_text(FAKE_INI)
        self.r = Repo(Path(self.tmp.name) / "repo")
        self.r.write("README.md", "a clean file\n")
        self.r.write("fpga/x.vhd", CRLF_TEXT)
        self.base = self.r.commit("base")
        self.r.git("update-ref", "refs/remotes/origin/main", self.base)

    def tearDown(self) -> None:
        self.tmp.cleanup()

    def checks(
        self, mode: str, *, fork: bool = False, base: str = "", stdin: str = "", ini: bool = True
    ) -> tuple[int, str]:
        """g20k.py check in the throwaway repository, returns (exit status, output)."""
        env = {"G20K_CONFIG_INI": str(self.ini if ini else self.r.path / "no-such.ini")}
        out = io.StringIO()
        with mock.patch.dict(os.environ, env), redirect_stdout(out):
            rc = checks.check(self.r.path, mode, fork, base, "origin" if mode == "push" else "", stdin)
        return rc, out.getvalue()

    def push(self, tip: str = "", remote_oid: str = "", ref: str = "refs/heads/main") -> tuple[int, str]:
        tip = tip or self.r.git("rev-parse", "HEAD")
        return self.checks("push", stdin=f"{ref} {tip} {ref} {remote_oid or self.base}\n")

    def assertRed(self, res: tuple[int, str], *needles: str) -> None:
        rc, out = res
        self.assertEqual(rc, 1, out)
        for n in needles:
            self.assertIn(n, out)
        # no credential is ever printed, whatever was found
        for v in (FAKE_TOKEN, FAKE_PASS):
            self.assertNotIn(v, out)

    def assertGreen(self, res: tuple[int, str], *needles: str) -> None:
        rc, out = res
        self.assertEqual(rc, 0, out)
        self.assertIn("checks: 0 findings", out)
        for n in needles:
            self.assertIn(n, out)


class StagedTest(Base):
    def test_clean_with_sample_sizes(self) -> None:
        self.r.write("README.md", "a clean file\nand one more line\n")
        self.r.git("add", "README.md")
        self.assertGreen(
            self.checks("staged"),
            "checks --staged (game20k):",
            "paths: 4 names checked against .gitignore, 0 excluded",
            "secrets: PASS 0 hits (1 values), TOKEN 0 hits (1 values), SSID 0 hits (1 values) in 4 files,",
            "ra-conditions: 4 files, 0 with a condition chain",
            "crlf: 1 CRLF files tracked, 1 changed files compared",
            "tests: host tests: 1 of 1 binaries passed",
        )

    def test_token(self) -> None:
        self.r.write("notes.txt", f"the token is {FAKE_TOKEN}, keep it\n")
        self.r.git("add", "notes.txt")
        self.assertRed(self.checks("staged"), "FINDING secrets: 1 lines hold a TOKEN value", "TOKEN 1 hits")

    def test_short_value_as_whole_word_only(self) -> None:
        self.r.write("notes.txt", f"{FAKE_SSID}\n{FAKE_SSID}work\nmy{FAKE_SSID}\n({FAKE_SSID})\n")
        self.r.git("add", "notes.txt")
        self.assertRed(self.checks("staged"), "FINDING secrets: 2 lines hold a SSID value")

    def test_binary_file_long_value_counts_short_does_not(self) -> None:
        self.r.write("blob.dat", b"\x00\x01 " + FAKE_SSID.encode() + b" \x00 " + FAKE_PASS.encode() + b"\x00")
        self.r.git("add", "blob.dat")
        self.assertRed(self.checks("staged"), "PASS 1 hits", "SSID 0 hits")

    def test_value_after_bytes_that_are_not_utf8(self) -> None:
        self.r.write(
            "dump.txt", b"\xff\xfe\x80 " + FAKE_TOKEN.encode() + b"\n\xc3\x28\n" + FAKE_TOKEN.encode() + b"\n"
        )
        self.r.git("add", "dump.txt")
        self.assertRed(self.checks("staged"), "FINDING secrets: 2 lines hold a TOKEN value")

    def test_placeholder_and_no_config(self) -> None:
        self.r.write("notes.txt", "YOUR_CONNECT_TOKEN\n")
        self.r.git("add", "notes.txt")
        self.assertGreen(self.checks("staged"))
        self.assertGreen(self.checks("staged", ini=False), "secrets: skipped, no config.ini here")

    def test_key_without_value_is_blind(self) -> None:
        self.ini.write_text(FAKE_INI.replace(f"SSID={FAKE_SSID}", "SSID=YOUR_WIFI_NAME"))
        self.assertRed(self.checks("staged"), "FINDING secrets: config.ini has no SSID value")

    def test_ignored_and_build_paths(self) -> None:
        self.r.write("roms/galaga.zip", b"PK\x03\x04")
        self.r.write("fw/CMakeFiles/x.txt", "x\n")
        self.r.git("add", "-f", "roms/galaga.zip", "fw/CMakeFiles/x.txt")
        self.assertRed(
            self.checks("staged"),
            "FINDING paths: roms/galaga.zip is excluded by .gitignore",
            "FINDING paths: fw/CMakeFiles/ is build output and tracked",
        )

    def test_crlf_turned_lf(self) -> None:
        self.r.write("fpga/x.vhd", CRLF_TEXT.replace(b"\r\n", b"\n"))
        self.r.git("add", "fpga/x.vhd")
        self.assertRed(self.checks("staged"), "FINDING crlf: the line ends of fpga/x.vhd changed")

    def test_crlf_kept(self) -> None:
        self.r.write("fpga/x.vhd", CRLF_TEXT + b"-- more\r\n")
        self.r.git("add", "fpga/x.vhd")
        self.assertGreen(self.checks("staged"), "1 changed files compared")

    def test_ra_chain_not_printed(self) -> None:
        self.r.write("docs/set.md", f"MemAddr: {RA_CHAIN}\n")
        self.r.git("add", "docs/set.md")
        rc, out = self.checks("staged")
        self.assertRed((rc, out), "FINDING ra-conditions: docs/set.md has 1 lines like a condition chain")
        self.assertNotIn(RA_CHAIN, out)

    def test_ra_single_condition(self) -> None:
        self.r.write("docs/prose.md", "a condition like 0xH0010=5 in prose\n")
        self.r.git("add", "docs/prose.md")
        self.assertGreen(self.checks("staged"))

    def test_host_tests(self) -> None:
        self.r.write("tests/host/Makefile", MAKEFILE.replace("$(FAIL)", "x"))
        self.assertRed(
            self.checks("staged"), "broken", "FINDING tests: the host tests failed (make -C tests/host)"
        )
        (self.r.path / "tests" / "host" / "Makefile").unlink()
        self.assertRed(self.checks("staged"), "FINDING tests: tests/host/Makefile is missing")


class PushTest(Base):
    def test_clean(self) -> None:
        self.r.write("README.md", "clean\n")
        self.r.commit("one")
        self.r.write("README.md", "clean again\n")
        self.r.commit("two")
        self.assertGreen(self.push(), "checks --push (game20k):", "in 2 commits,")

    def test_token_in_commit_message(self) -> None:
        self.r.commit(f"token {FAKE_TOKEN} by mistake")
        self.assertRed(self.push(), "FINDING secrets: 1 lines hold a TOKEN value")

    def test_short_value_in_message_as_word(self) -> None:
        self.r.commit(f"at {FAKE_SSID}, and {FAKE_SSID}s")
        self.assertRed(self.push(), "FINDING secrets: 1 lines hold a SSID value")

    def test_token_in_tag_message(self) -> None:
        self.r.git("tag", "-a", "v1", "-m", f"release {FAKE_TOKEN}")
        oid = self.r.git("rev-parse", "v1")
        self.assertRed(
            self.checks("push", stdin=f"refs/tags/v1 {oid} refs/tags/v1 {'0' * 40}\n"),
            "FINDING secrets: 1 lines hold a TOKEN value",
        )

    def test_token_in_a_tag_on_a_tree(self) -> None:
        # no commit behind it, still the push carries its message
        tree = self.r.git("rev-parse", "HEAD^{tree}")
        self.r.git("tag", "-a", "t", tree, "-m", f"tree {FAKE_TOKEN}")
        oid = self.r.git("rev-parse", "t")
        self.assertRed(
            self.checks("push", stdin=f"refs/tags/t {oid} refs/tags/t {'0' * 40}\n"),
            "FINDING secrets: 1 lines hold a TOKEN value",
        )

    def test_crlf_lost_in_a_middle_commit(self) -> None:
        self.r.write("fpga/x.vhd", CRLF_TEXT.replace(b"\r\n", b"\n"))
        self.r.commit("lf")
        self.r.write("fpga/x.vhd", CRLF_TEXT)
        self.r.commit("crlf again")
        self.assertRed(self.push(), "FINDING crlf: the line ends of fpga/x.vhd changed")

    def test_deletion_only(self) -> None:
        rc, out = self.push(tip="0" * 40)
        self.assertEqual(rc, 0, out)
        self.assertIn("nothing outgoing", out)

    def test_all_on_the_remote(self) -> None:
        self.assertGreen(self.push(ref="refs/heads/other"), "in no new commits, all on origin already")


class CITest(Base):
    def test_clean(self) -> None:
        self.assertGreen(self.checks("ci"), "checks --ci (game20k):")

    def test_crlf_lost_since_base(self) -> None:
        self.r.write("fpga/x.vhd", CRLF_TEXT.replace(b"\r\n", b"\n"))
        self.r.write("fpga/y.vhd", CRLF_TEXT)
        self.r.commit("lf")
        self.r.write("README.md", "later\n")
        self.r.commit("later")
        self.assertGreen(self.checks("ci"))
        self.assertRed(self.checks("ci", base=self.base), "FINDING crlf: the line ends of fpga/x.vhd changed")

    def test_unknown_base(self) -> None:
        self.assertRed(
            self.checks("ci", base="1" * 40), f"FINDING crlf: base {'1' * 40} is not in this clone"
        )

    def test_no_crlf_file(self) -> None:
        self.r.write("fpga/x.vhd", CRLF_TEXT.replace(b"\r\n", b"\n"))
        self.r.commit("lf")
        self.assertRed(self.checks("ci"), "FINDING crlf: no CRLF file tracked")

    def test_fork_without_host_tests(self) -> None:
        fork = Repo(self.r.path / "external" / "FPGA-Companion")
        fork.write("src/x.c", CRLF_TEXT)
        fork.commit("fork")
        (self.r.path / "tests" / "host" / "Makefile").unlink()
        self.assertGreen(self.checks("ci", fork=True), "checks --ci (fork):")

    def test_no_fork(self) -> None:
        with redirect_stdout(io.StringIO()), mock.patch("sys.stderr", io.StringIO()):
            self.assertEqual(checks.check(self.r.path, "ci", True, "", "", ""), 2)


class IniTest(unittest.TestCase):
    def test_values_as_the_firmware_reads_them(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            ini = Path(tmp) / "config.ini"
            ini.write_bytes(
                b" ; PASS=commented\r\n[WIFI]\r\nssid = a b ; c\r\nPASS=\r\nTOKEN=YOUR_TOKEN\npass=xy\n"
            )
            values = checks.ini_values(ini)
        self.assertEqual(values, {"PASS": [b"xy"], "TOKEN": [], "SSID": [b"a b"]})


if __name__ == "__main__":
    unittest.main()
