#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-only
# Copyright (C) 2026 scullymi
"""Pinned dependencies against their newest upstream releases.

Read-only: asks GitHub over HTTPS (git ls-remote, and the public compare API for the two
forks, no token needed), changes nothing and fetches nothing into the checkouts. Run it by
hand about once a month and before a release. tests/README.md says what to do with the result.

Usage: scripts/deps_status.py
"""
import json
import os
import re
import subprocess
import sys
import urllib.request
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent

#: name, checkout path, upstream repository, our fork on GitHub or None, remark
DEPS = [
    ('pico-sdk', 'external/pico-sdk', 'raspberrypi/pico-sdk', None,
     'brings lwIP, mbedTLS, BTstack, cyw43'),
    ('TinyUSB', 'external/tinyusb', 'hathach/tinyusb', 'scullymi/tinyusb',
     'our fork carries the hid_host fix'),
    ('FPGA-Companion', 'external/FPGA-Companion', 'MiSTle-Dev/FPGA-Companion',
     'scullymi/FPGA-Companion', "Till's upstream, merged into branch game20k"),
    ('rcheevos', 'external/FPGA-Companion/src/rcheevos', 'RetroAchievements/rcheevos', None,
     'changes the User-Agent sent to RetroAchievements'),
    ('Unity', 'external/unity', 'ThrowTheSwitch/Unity', None, 'tests only'),
]
RELEASE = re.compile(r'^v?(\d+)\.(\d+)(?:\.(\d+))?$')


def git(*args):
    """Output of a read-only git command, '' when it fails."""
    env = dict(os.environ, GIT_OPTIONAL_LOCKS='0')
    r = subprocess.run(['git', *args], capture_output=True, text=True, env=env)
    return r.stdout.strip() if r.returncode == 0 else ''


def version(tag):
    """(major, minor, patch) of a release tag, None for anything else."""
    m = RELEASE.match(tag)
    return tuple(int(x or 0) for x in m.groups()) if m else None


def latest_release(repo):
    """The highest release tag of the upstream repository, or '?' when GitHub does not answer."""
    out = git('ls-remote', '--tags', '--refs', f'https://github.com/{repo}.git')
    tags = [line.rsplit('/', 1)[-1] for line in out.splitlines()]
    tags = [t for t in tags if version(t)]
    return max(tags, key=version) if tags else '?'


def upstream_lead(upstream, fork, sha):
    """Commits on the upstream default branch that our fork commit lacks, or None."""
    head = git('ls-remote', '--symref', f'https://github.com/{upstream}.git', 'HEAD')
    m = re.search(r'refs/heads/(\S+)\s+HEAD', head)
    if not m:
        return None
    owner, name = fork.split('/')
    url = f'https://api.github.com/repos/{upstream}/compare/{m.group(1)}...{owner}:{name}:{sha}'
    try:
        with urllib.request.urlopen(url, timeout=20) as r:
            return json.load(r).get('behind_by')
    except (OSError, ValueError):
        return None   # offline, rate limit, or our commit is not on GitHub yet


def main():
    rows = []
    for name, path, upstream, fork, remark in DEPS:
        pinned = git('-C', str(ROOT / path), 'describe', '--tags') or '?'
        newest = latest_release(upstream)
        base = re.sub(r'-\d+-g[0-9a-f]+$', '', pinned)   # the release a commit builds on
        if version(base) and version(newest) and version(newest) > version(base):
            state = f'newer release {newest}'
        elif newest == '?' or not version(base):
            state = 'unknown'
        else:
            state = 'up to date'
        # for our forks the release tag says little, what counts is what upstream added since
        if fork:
            lead = upstream_lead(upstream, fork, git('-C', str(ROOT / path), 'rev-parse', 'HEAD'))
            state += ', upstream ' + ('?' if lead is None else f'{lead} commits ahead')
        rows.append((name, pinned, newest, state, remark))

    # the toolchain has no git repository to ask, only the pinned name is shown
    wf = (ROOT / '.github/workflows/pico2w-firmware.yml').read_text(encoding='utf-8')
    tc = re.search(r'arm-gnu-toolchain-([0-9.]+rel[0-9]+)', wf)
    rows.append(('Arm toolchain', tc.group(1) if tc else '?', '-', 'check developer.arm.com',
                 'CI only, same SHA-256 in both workflows'))

    widths = [max(len(r[i]) for r in rows) for i in range(4)]
    for r in rows:
        print('  '.join(r[i].ljust(widths[i]) for i in range(4)) + '  ' + r[4])
    return 0


if __name__ == '__main__':
    sys.exit(main())
