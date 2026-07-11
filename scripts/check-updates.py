#!/usr/bin/env python3
"""
Check (and optionally apply) upstream updates for every pinned dependency.

Reads the *current* pins straight from the source files (single source of truth)
and compares them against upstream:

  - Docker images  -> Docker Hub tags API
  - git clones     -> `git ls-remote` (default-branch HEAD)          (no API rate limit)
  - EDCB           -> `git ls-remote --tags` (work-plus-s-YYMMDD)
  - KonomiTV       -> upstream release tags (vX.Y.Z)  [report only; needs a fork rebase]

No external dependencies (stdlib + git). Exit code (check mode): 0 if everything is
current, 1 if any update is available (handy for cron / CI).

Usage:
  python3 scripts/check-updates.py            # report only
  python3 scripts/check-updates.py --apply    # rewrite the pins in-place, then rebuild
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


def sha_after(text: str, marker: str) -> str:
    m = re.search(re.escape(marker) + r".*?checkout ([0-9a-f]{7,40})", text, re.S)
    return m.group(1) if m else ""


def git_head(url: str) -> str:
    out = subprocess.check_output(["git", "ls-remote", url, "HEAD"], text=True, timeout=40)
    return out.split()[0]


def git_tags(url: str) -> list[str]:
    out = subprocess.check_output(["git", "ls-remote", "--tags", url], text=True, timeout=40)
    return [ln.split("refs/tags/")[-1] for ln in out.splitlines()
            if "refs/tags/" in ln and not ln.rstrip().endswith("^{}")]


def tag_commit(url: str, tag: str) -> str:
    """Peeled commit SHA of a tag (works for both lightweight and annotated tags)."""
    out = subprocess.check_output(["git", "ls-remote", "--tags", url, tag, tag + "^{}"],
                                  text=True, timeout=40)
    plain = peeled = ""
    for ln in out.splitlines():
        sha, ref = ln.split("\t")
        if ref.endswith("^{}"):
            peeled = sha
        else:
            plain = sha
    return peeled or plain


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


def result(name, kind, current, latest, edits, note, manual=False) -> dict:
    return {"name": name, "kind": kind, "current": current, "latest": latest,
            "edits": edits, "note": note, "manual": manual,
            "outdated": current != latest}


# --- one function per dependency; returns a result() ---

def check_mirakc():
    token = re.search(r"(mirakc/mirakc:\S+)", read("docker-compose.yaml")).group(1)
    cur = token.split(":", 1)[1]
    latest = max((t for t in hub_tags("mirakc/mirakc")
                  if re.fullmatch(r"\d+\.\d+\.\d+-alpine", t)), key=numkey)
    edits = ([(f, f"mirakc/mirakc:{cur}", f"mirakc/mirakc:{latest}")
              for f in ("docker-compose.yaml", "mirakc/capture_test.sh", "README.md")]
             if cur != latest else [])
    return result("mirakc", "image", cur, latest, edits, "docker-compose.yaml, capture_test.sh")


def check_alpine():
    cur = re.search(r"FROM alpine:(\S+)", read("b25/Dockerfile")).group(1)
    latest = max((t for t in hub_tags("library/alpine") if re.fullmatch(r"\d+\.\d+", t)), key=numkey)
    edits = ([(f, f"alpine:{cur}", f"alpine:{latest}") for f in ("b25/Dockerfile", "bcas/Dockerfile")]
             if cur != latest else [])
    return result("alpine", "image", cur, latest, edits, "b25/Dockerfile, bcas/Dockerfile")


def check_git(name, url, dockerfile):
    # anchor on the owner/repo path (unique to the clone line, unlike a bare repo
    # name which can also appear in comments)
    cur = sha_after(read(dockerfile), url.split("github.com/")[-1])
    latest_full = git_head(url)
    outdated = not latest_full.startswith(cur)
    new = latest_full[:12]
    edits = [(dockerfile, f"checkout {cur}", f"checkout {new}")] if outdated else []
    return result(name, "git", cur, new if outdated else cur, edits, dockerfile)


def check_edcb():
    txt = read("edcb/Dockerfile")
    cur_tag = re.search(r"-b (work-plus-s-\S+)", txt).group(1)
    cur_sha = sha_after(txt, "xtne6f/EDCB.git")
    latest_tag = max((t for t in git_tags("https://github.com/xtne6f/EDCB")
                      if re.fullmatch(r"work-plus-s-\d+", t)), key=numkey)
    edits = []
    if cur_tag != latest_tag:
        new_sha = tag_commit("https://github.com/xtne6f/EDCB", latest_tag)[:12]
        edits = [("edcb/Dockerfile", f"-b {cur_tag}", f"-b {latest_tag}"),
                 ("edcb/Dockerfile", f"checkout {cur_sha}", f"checkout {new_sha}")]
    return result("EDCB", "tag", cur_tag, latest_tag, edits, "edcb/Dockerfile")


def check_konomitv():
    cur = re.search(r"VERSION = '([^']+)'", read("KonomiTV/server/app/constants.py")).group(1)
    latest = max((t for t in git_tags("https://github.com/tsukumijima/KonomiTV")
                  if re.fullmatch(r"v\d+\.\d+\.\d+", t)), key=numkey).lstrip("v")
    # KonomiTV carries a local patch (bind-0.0.0.0), so an update means rebasing the fork —
    # not something --apply should do automatically.
    return result("KonomiTV", "release", cur, latest, [],
                  "manual: rebase fork onto new tag, then bump submodule", manual=True)


CHECKS = [
    check_mirakc,
    check_alpine,
    lambda: check_git("libaribb25", "https://github.com/tsukumijima/libaribb25", "b25/Dockerfile"),
    lambda: check_git("px4_drv", "https://github.com/yyya-nico/px4_drv", "bcas/Dockerfile"),
    check_edcb,
    lambda: check_git("EDCB_Material_WebUI", "https://github.com/EMWUI/EDCB_Material_WebUI", "edcb/Dockerfile"),
    lambda: check_git("BonDriver_LinuxMirakc", "https://github.com/matching/BonDriver_LinuxMirakc", "edcb/Dockerfile"),
    check_konomitv,
]


def apply_edits(edits) -> list:
    changed = []
    for rel, old, new in edits:
        p = ROOT / rel
        txt = p.read_text(encoding="utf-8")
        if old in txt and old != new:
            p.write_text(txt.replace(old, new), encoding="utf-8")
            changed.append((rel, old, new))
    return changed


def main() -> int:
    do_apply = "--apply" in sys.argv[1:]
    results = []
    for fn in CHECKS:
        try:
            results.append(fn())
        except Exception as exc:
            results.append(result("(check failed)", "error", "-", str(exc)[:50], [], "", manual=True))

    w = [max(len(str(r[k])) for r in results) for k in ("name", "kind", "current", "latest")]
    print(f"  {'DEPENDENCY':<{w[0]}}  {'KIND':<{w[1]}}  {'CURRENT':<{w[2]}}  {'LATEST':<{w[3]}}")
    print("  " + "-" * (sum(w) + 10))
    for r in results:
        flag = ""
        if r["kind"] == "error":
            flag = "  ✗"
        elif r["outdated"]:
            flag = "  ⬆ update (manual)" if r["manual"] else "  ⬆ update"
        print(f"  {r['name']:<{w[0]}}  {r['kind']:<{w[1]}}  {r['current']:<{w[2]}}  {r['latest']:<{w[3]}}{flag}")
    print()

    auto = [r for r in results if r["outdated"] and r["edits"]]
    manual = [r for r in results if r["outdated"] and r["manual"]]

    if not auto and not manual:
        print("All dependencies are up to date. ✓")
        return 0

    if do_apply:
        applied = []
        for r in auto:
            applied += apply_edits(r["edits"])
        if applied:
            print("Applied:")
            for rel, old, new in applied:
                print(f"  • {rel}: {old.split()[-1]} -> {new.split()[-1]}")
            print("\nNow rebuild the affected services, e.g.:  docker compose up -d --build")
        for r in manual:
            print(f"  • {r['name']}: {r['current']} -> {r['latest']}  (skipped — {r['note']})")
        return 0

    print(f"{len(auto) + len(manual)} update(s) available:")
    for r in auto + manual:
        tail = "  [--apply]" if r["edits"] else f"  ({r['note']})"
        print(f"  • {r['name']}: {r['current']} -> {r['latest']}{tail}")
    print("\nRun with --apply to rewrite the auto-updatable pins.")
    return 1


if __name__ == "__main__":
    sys.exit(main())
