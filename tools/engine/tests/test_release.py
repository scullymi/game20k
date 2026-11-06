# SPDX-License-Identifier: MIT
# Copyright (C) 2026 scullymi
"""@file
@brief Tests for the version of a release, in a git repository of its own."""

import os
import subprocess
import tempfile
import unittest
from pathlib import Path

from tools.engine import release
from tools.engine.host import StepError

# no hooks, no signing: plumbing only, and a signer that would fail
GIT = ["git", "-c", "gpg.ssh.program=false", "-c", "tag.gpgSign=false", "-c", "tag.forceSignAnnotated=false"]


class VersionTest(unittest.TestCase):
    def setUp(self) -> None:
        self.tmp = tempfile.TemporaryDirectory()
        self.root = Path(self.tmp.name)
        self.git("init", "-q")
        self.head = ""

    def tearDown(self) -> None:
        self.tmp.cleanup()

    def git(self, *args: str) -> str:
        env = os.environ | {"GIT_AUTHOR_NAME": "t", "GIT_AUTHOR_EMAIL": "t@example.org"}
        env |= {"GIT_COMMITTER_NAME": "t", "GIT_COMMITTER_EMAIL": "t@example.org"}
        done = subprocess.run([*GIT, "-C", str(self.root), *args], capture_output=True, text=True, env=env)
        self.assertEqual(done.returncode, 0, done.stderr)
        return done.stdout.strip()

    def commit(self) -> None:
        tree = self.git("write-tree")
        parent = ["-p", self.head] if self.head else []
        self.head = self.git("commit-tree", "--no-gpg-sign", *parent, "-m", "c", tree)
        self.git("update-ref", "HEAD", self.head)

    def test_tools_tags_are_no_version(self) -> None:
        self.commit()
        self.git("tag", "-a", "-m", "v1.2.3", "v1.2.3")
        self.assertEqual(release.tree_version(self.root), "1.2.3")
        self.assertTrue(release.on_version_tag(self.root))
        # tools.yml tags its releases in the same repository, nearer than the version
        self.commit()
        self.git("tag", "tools-0123456789ab")
        version, _, commit = release.tree_version(self.root).rpartition("-g")
        self.assertEqual(version, "1.2.3-1")
        self.assertTrue(self.head.startswith(commit))
        self.assertFalse(release.on_version_tag(self.root))

    def test_a_failing_git_stops(self) -> None:
        with self.assertRaises(StepError):
            release.git(self.root, "rev-parse", "--verify", "no-such-ref")
        self.assertEqual(release.git(self.root, "config", "--get", "no.such", check=False), "")

    def test_no_repository_gives_no_version(self) -> None:
        with tempfile.TemporaryDirectory() as other, self.assertRaises(StepError):
            release.tree_version(Path(other))


if __name__ == "__main__":
    unittest.main()
