#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-only
# Copyright (C) 2026 scullymi
"""Pinned dependencies against their newest upstream releases, and the HDL copied into fpga/
against its upstream repositories.

Read-only: asks GitHub over HTTPS (git ls-remote and the public API), changes nothing and fetches
nothing into the checkouts. The API needs a token for more than 60 requests an hour: GITHUB_TOKEN,
or else the token of a logged-in gh. The workflow upstream.yml runs --vendored --ci every Saturday. tests/README.md says what
to do with the result.

Usage: scripts/deps_status.py [--vendored] [--ci]
  --vendored  only the copied HDL
  --ci        exit 1 when a copied file changed upstream since its review, or GitHub did not answer
"""
import json
import os
import re
import subprocess
import sys
import time
import urllib.error
import urllib.parse
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
#: HDL copied into fpga/: name, upstream repository, commit the copy is taken from, newest
#: upstream commit already looked at, local folder, the same folder upstream, files in the local
#: folder that come from elsewhere, further upstream paths. Every file under the local folder
#: except README.md and LICENSE is watched. After looking at a reported change, set the fourth
#: field to the upstream commit named in the report.
VENDORED = [
    ('Galaga', 'DECAfpga/Arcade_Galaga', 'e06ba91', 'e06ba91',
     'fpga/galaga_hdmi/src/rtl_dar', 'rtl_dar', (), ()),
    ('Pac-Man', 'MiSTer-devel/Arcade-Pacman_MiSTer', '648172d', '6b5ccb0',
     'fpga/pacman_hdmi/src/rtl_pacman', 'rtl',
     ('g20k_dpram.vhd', 'pacman_mirror.vhd', 'sn76489_top.vhd', 'ym2149.vhd'), ()),
    ('1942', 'jotego/jtcores', '0b197ca', '548b87b',
     'fpga/g1942_hdmi/src/jtcores', '', (), ('modules/jt12',)),
    ('jt49', 'jotego/jt49', '7f6abfd', '47301ed', 'fpga/g1942_hdmi/src/jt49/hdl', 'hdl', (), ()),
    ('MiSTeryNano', 'MiSTle-Dev/MiSTeryNano', 'c8e4601', 'c8e4601', 'fpga/common/src/misc',
     'src/misc', ('sd_card.v', 'sd_rw.v', 'sdcmd_ctrl.v'),
     ('src/tang/nano20k/gowin_dpb/sector_dpram.v',)),
    ('Nanomig', 'MiSTle-Dev/Nanomig', 'df97f03', '5a33804', 'fpga/common/src/misc', 'src/misc',
     ('hid.v', 'mcu_spi.v', 'osd_u8g2.v', 'sysctrl.v'), ()),
    ('hdmi', 'hdl-util/hdmi', '08936f6', '83b1c95', 'fpga/common/src/hdmi', 'src', (), ()),
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


def token():
    """GITHUB_TOKEN, or the token of a logged-in gh, or ''."""
    if os.environ.get('GITHUB_TOKEN'):
        return os.environ['GITHUB_TOKEN']
    try:
        r = subprocess.run(['gh', 'auth', 'token'], capture_output=True, text=True, timeout=10)
        return r.stdout.strip() if r.returncode == 0 else ''
    except (OSError, subprocess.TimeoutExpired):
        return ''


TOKEN = None


def api(path):
    """JSON of a GitHub API request, authenticated when a token is at hand."""
    global TOKEN
    if TOKEN is None:
        TOKEN = token()
    req = urllib.request.Request('https://api.github.com/' + path, headers={
        'Accept': 'application/vnd.github+json', 'User-Agent': 'game20k-deps-status'})
    if TOKEN:
        req.add_header('Authorization', 'Bearer ' + TOKEN)
    with urllib.request.urlopen(req, timeout=20) as r:
        return json.load(r)


def why(e):
    """Short reason of a failed API request, with the reset time of an exhausted limit."""
    if isinstance(e, urllib.error.HTTPError):
        reset = e.headers.get('X-RateLimit-Reset')
        if e.code in (403, 429) and e.headers.get('X-RateLimit-Remaining') == '0' and reset:
            return (f'API limit used up until {time.strftime("%H:%M", time.localtime(int(reset)))}'
                    + ('' if TOKEN else ', set GITHUB_TOKEN or log in with gh'))
        return f'HTTP {e.code} {e.reason}'
    return str(e)


def vendored():
    """Report lines for the copied HDL, and whether something needs a look."""
    lines, look = [], False
    for name, repo, pinned, reviewed, local, there, other, extra in VENDORED:
        folder = ROOT / local
        ours = {f'{there}/{p.relative_to(folder)}'.lstrip('/') for p in folder.rglob('*')
                if p.is_file() and p.name not in ('README.md', 'LICENSE') + other}
        ours |= set(extra)
        try:
            branch = api(f'repos/{repo}')['default_branch']
            cmp = api(f'repos/{repo}/compare/{reviewed}...{branch}')
        except (OSError, ValueError, KeyError) as e:
            lines.append(f'{name}: GitHub did not answer ({why(e)})')
            look = True
            continue
        files = cmp.get('files', [])
        hit = sorted(f['filename'] for f in files if f['filename'] in ours)
        # the API lists at most 300 files and 250 commits of a comparison
        if len(files) >= 300 or cmp.get('total_commits', 0) > 250:
            lines.append(f'{name}: {cmp["ahead_by"]} commits since {reviewed}, too many for the '
                         f'API, compare by hand')
            look = True
        elif not hit:
            lines.append(f'{name}: none of our {len(ours)} files changed since {reviewed} '
                         f'({cmp["ahead_by"]} commits upstream)')
        else:
            look = True
            head = cmp['commits'][-1]['sha'][:7]
            lines.append(f'{name}: {len(hit)} of our files changed since {reviewed}, '
                         f'upstream now {head}, copy taken at {pinned}')
            shas = {c['sha'] for c in cmp['commits']}
            for fn in hit:
                q = urllib.parse.quote(fn)
                for c in api(f'repos/{repo}/commits?path={q}&sha={branch}&per_page=30'):
                    if c['sha'] in shas:
                        msg = c['commit']['message'].splitlines()[0]
                        lines.append(f'  {fn}: {c["sha"][:7]} {c["commit"]["committer"]["date"][:10]} {msg}')
    return lines, look


def main():
    args = set(sys.argv[1:])
    lines, look = vendored()
    report = '\n'.join(lines)
    print('Copied HDL against upstream:\n' + report)
    if os.environ.get('GITHUB_STEP_SUMMARY'):
        with open(os.environ['GITHUB_STEP_SUMMARY'], 'a', encoding='utf-8') as f:
            f.write('## Copied HDL against upstream\n\n```\n' + report + '\n```\n')
    if '--vendored' in args:
        return 1 if look and '--ci' in args else 0
    print()
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
    return 1 if look and '--ci' in args else 0


if __name__ == '__main__':
    sys.exit(main())
