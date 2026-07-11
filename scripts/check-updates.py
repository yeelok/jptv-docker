#!/usr/bin/env python3
"""
Check upstream updates for every pinned dependency in this stack.

Reads the *current* pins straight from the source files (single source of truth)
and compares them against upstream:

  - Docker images  -> Docker Hub tags API
  - git clones     -> `git ls-remote` (default-branch HEAD)          (no API rate limit)
  - EDCB           -> `git ls-remote --tags` (work-plus-s-YYMMDD)
  - KonomiTV       -> upstream release tags (vX.Y.Z)

No external dependencies (stdlib + git). Exit code: 0 if everything is current,
1 if any update is available (handy for cron / CI).

Usage:  python3 scripts/check-updates.py
"""
from __future__ import annotations

import json
import re
import subprocess
import sys
import urllib.request
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent


def read(rel: str) -> str:
    return (ROOT / rel).read_text(encoding="utf-8")


def sha_after(text: str, marker: str) -> str | None:
    """The `git ... checkout <sha>` that follows the first occurrence of `marker`."""
    m = re.search(re.escape(marker) + r".*?checkout ([0-9a-f]{7,40})", text, re.S)
    return m.group(1) if m else None


def git_head(url: str) -> str:
    """Full SHA of the remote's default branch (HEAD)."""
    out = subprocess.check_output(["git", "ls-remote", url, "HEAD"], text=True, timeout=40)
    return out.split()[0]


def git_tags(url: str) -> list[str]:
    out = subprocess.check_output(["git", "ls-remote", "--tags", url], text=True, timeout=40)
    tags = []
    for line in out.splitlines():
        ref = line.split("refs/tags/")[-1]
        if ref and not ref.endswith("^{}"):
            tags.append(ref)
    return tags


def hub_tags(repo: str) -> list[str]:
    tags: list[str] = []
    url = f"https://hub.docker.com/v2/repositories/{repo}/tags?page_size=100"
    while url and len(tags) < 500:
        req = urllib.request.Request(url, headers={"User-Agent": "jptv-update-check"})
        with urllib.request.urlopen(req, timeout=30) as r:
            data = json.load(r)
        tags += [t["name"] for t in data.get("results", [])]
        url = data.get("next")
    return tags


def numkey(s: str) -> list[int]:
    return [int(x) for x in re.findall(r"\d+", s)]


# --- checks: each returns (name, kind, current, latest, pinned_in) ---

def check_mirakc():
    cur = re.search(r"mirakc/mirakc:(\S+)", read("docker-compose.yaml")).group(1)
    cand = [t for t in hub_tags("mirakc/mirakc") if re.fullmatch(r"\d+\.\d+\.\d+-alpine", t)]
    latest = max(cand, key=numkey)
    return ("mirakc", "image", cur, latest, "docker-compose.yaml, mirakc/capture_test.sh")


def check_alpine():
    cur = re.search(r"FROM alpine:(\S+)", read("b25/Dockerfile")).group(1)
    cand = [t for t in hub_tags("library/alpine") if re.fullmatch(r"\d+\.\d+", t)]
    latest = max(cand, key=numkey)
    return ("alpine", "image", cur, latest, "b25/Dockerfile, bcas/Dockerfile")


def check_git(name, url, current, pinned_in):
    latest = git_head(url)
    ok = latest.startswith(current)
    return (name, "git", current, latest[: len(current)] if ok else latest[:12], pinned_in)


def check_edcb():
    txt = read("edcb/Dockerfile")
    cur = re.search(r"-b (work-plus-s-\S+)", txt).group(1)
    dated = [t for t in git_tags("https://github.com/xtne6f/EDCB")
             if re.fullmatch(r"work-plus-s-\d+", t)]
    latest = max(dated, key=numkey)
    return ("EDCB", "tag", cur, latest, "edcb/Dockerfile")


def check_konomitv():
    desc = subprocess.check_output(
        ["git", "-C", str(ROOT / "KonomiTV"), "describe", "--tags", "--abbrev=0"],
        text=True, timeout=20).strip()
    vt = [t for t in git_tags("https://github.com/tsukumijima/KonomiTV")
          if re.fullmatch(r"v\d+\.\d+\.\d+", t)]
    latest = max(vt, key=numkey)
    return ("KonomiTV", "release", desc, latest, "submodule (fork of tsukumijima/KonomiTV)")


CHECKS = [
    check_mirakc,
    check_alpine,
    lambda: check_git("libaribb25", "https://github.com/tsukumijima/libaribb25",
                      sha_after(read("b25/Dockerfile"), "libaribb25.git"), "b25/Dockerfile"),
    lambda: check_git("px4_drv", "https://github.com/yyya-nico/px4_drv",
                      sha_after(read("bcas/Dockerfile"), "yyya-nico/px4_drv"),
                      "bcas/Dockerfile + px4_drv submodule"),
    check_edcb,
    lambda: check_git("EDCB_Material_WebUI", "https://github.com/EMWUI/EDCB_Material_WebUI",
                      sha_after(read("edcb/Dockerfile"), "EDCB_Material_WebUI.git"), "edcb/Dockerfile"),
    lambda: check_git("BonDriver_LinuxMirakc", "https://github.com/matching/BonDriver_LinuxMirakc",
                      sha_after(read("edcb/Dockerfile"), "BonDriver_LinuxMirakc.git"), "edcb/Dockerfile"),
    check_konomitv,
]


def main() -> int:
    rows, updates, errors = [], [], []
    for fn in CHECKS:
        try:
            name, kind, cur, latest, where = fn()
        except Exception as exc:  # never let one dependency abort the whole run
            rows.append(("(check failed)", "error", "-", str(exc)[:50], ""))
            errors.append(True)
            continue
        outdated = (cur != latest)
        rows.append((name, kind, cur, latest, where if outdated else ""))
        if outdated:
            updates.append((name, cur, latest, where))

    w = [max(len(str(r[i])) for r in rows) for i in range(4)]
    print(f"  {'DEPENDENCY':<{w[0]}}  {'KIND':<{w[1]}}  {'CURRENT':<{w[2]}}  {'LATEST':<{w[3]}}")
    print("  " + "-" * (w[0] + w[1] + w[2] + w[3] + 10))
    for name, kind, cur, latest, where in rows:
        flag = "  ⬆ update" if (cur != latest and kind != "error") else ("  ✗" if kind == "error" else "")
        print(f"  {name:<{w[0]}}  {kind:<{w[1]}}  {cur:<{w[2]}}  {latest:<{w[3]}}{flag}")

    print()
    if updates:
        print(f"{len(updates)} update(s) available:")
        for name, cur, latest, where in updates:
            print(f"  • {name}: {cur} -> {latest}   (edit: {where})")
    else:
        print("All dependencies are up to date. ✓")
    return 1 if updates or errors else 0


if __name__ == "__main__":
    sys.exit(main())
