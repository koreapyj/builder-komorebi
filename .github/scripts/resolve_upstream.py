#!/usr/bin/env python3
"""Resolve the upstream refs for the stable, beta and main channels.

Tags are classified by name, not by upstream's GitHub "prerelease" flag: upstream publishes
some betas (1.1.0-beta2, 1.0.0-beta) as normal releases.
"""

import json
import os
import re
import subprocess
import sys
import urllib.request

STABLE_RE = re.compile(r"^(\d+)\.(\d+)\.(\d+)$")
BETA_RE = re.compile(r"^(\d+)\.(\d+)\.(\d+)-beta(\d*)$")


def version_key(tag):
    """Sort key for a stable or beta tag, or None for any other tag shape."""
    m = STABLE_RE.match(tag)
    if m:
        return (int(m[1]), int(m[2]), int(m[3]), 1, 0)
    m = BETA_RE.match(tag)
    if m:
        return (int(m[1]), int(m[2]), int(m[3]), 0, int(m[4] or 0))
    return None


def is_stable(tag):
    return STABLE_RE.match(tag) is not None


def ls_remote(repo):
    """Return ({tag: commit sha}, main sha) from `git ls-remote`."""
    out = subprocess.run(
        ["git", "ls-remote", "--tags", "--heads", f"https://github.com/{repo}.git"],
        check=True, capture_output=True, text=True,
    ).stdout
    tags, main = {}, None
    for line in out.splitlines():
        sha, ref = line.split("\t", 1)
        if ref == "refs/heads/main":
            main = sha
        elif ref.startswith("refs/tags/"):
            name = ref[len("refs/tags/"):]
            if name.endswith("^{}"):  # peeled annotated tag wins
                tags[name[:-3]] = sha
            else:
                tags.setdefault(name, sha)
    return tags, main


def releases(repo, token):
    """All non-draft releases of `repo` as [(tag, prerelease)]."""
    result, page = [], 1
    while True:
        req = urllib.request.Request(
            f"https://api.github.com/repos/{repo}/releases?per_page=100&page={page}",
            headers={"Accept": "application/vnd.github+json", "X-GitHub-Api-Version": "2022-11-28"},
        )
        if token:
            req.add_header("Authorization", f"Bearer {token}")
        with urllib.request.urlopen(req, timeout=30) as resp:
            batch = json.load(resp)
        result += [(r["tag_name"], bool(r["prerelease"])) for r in batch if not r.get("draft")]
        if len(batch) < 100:
            return result
        page += 1


def pick(rels, tags):
    """Return (stable_tag, newest_beta_tag, beta_tag_or_None, warnings)."""
    warnings = []
    stable, beta = [], []
    for tag, pre in rels:
        if tag not in tags:
            warnings.append(f"release {tag} has no tag in the upstream repository; ignored")
        elif is_stable(tag) and not pre:
            stable.append(tag)
        elif BETA_RE.match(tag):
            beta.append(tag)
        elif pre:
            warnings.append(f"prerelease {tag} does not look like X.Y.Z-beta<k>; ignored")
    best_stable = max(stable, key=version_key, default=None)
    best_beta = max(beta, key=version_key, default=None)
    if best_beta and best_stable and version_key(best_beta) <= version_key(best_stable):
        return best_stable, best_beta, None, warnings
    return best_stable, best_beta, best_beta, warnings


def main():
    repo = os.environ.get("UPSTREAM_REPO", "BeerEgg2001/Komorebi")
    n = os.environ["RUN_NUMBER"]
    tags, main_sha = ls_remote(repo)
    if not main_sha:
        sys.exit(f"::error::upstream {repo} has no main branch")
    stable, newest_beta, beta, warnings = pick(releases(repo, os.environ.get("GH_TOKEN")), tags)
    for w in warnings:
        print(f"::warning::{w}")

    out = {}

    def channel(name, ref, sha, release_tag, label, version_name):
        out.update({f"{name}_ref": ref, f"{name}_sha": sha, f"{name}_release_tag": release_tag,
                    f"{name}_label": label, f"{name}_version_name": version_name})

    if stable:
        channel("stable", f"refs/tags/{stable}", tags[stable], f"v{stable}-{n}", f"v{stable}-{n}",
                f"{stable}-{n}")
    else:
        print(f"::warning::upstream {repo} has no stable (X.Y.Z) release; the stable channel is not built")
        channel("stable", "", "", "", "", "")
    if beta:
        channel("beta", f"refs/tags/{beta}", tags[beta], f"v{beta}-{n}", f"v{beta}-{n}", f"{beta}-{n}")
    else:
        channel("beta", "", "", "", "", "")
    channel("main", "refs/heads/main", main_sha, "", f"main-{n}", f"main-{n}")
    out["upstream_stable"] = stable or ""
    out["upstream_newest_beta"] = newest_beta or ""

    if beta:
        beta_line = f"`{beta}` ({tags[beta][:7]})"
    else:
        beta_line = f"none (newest beta `{newest_beta or '-'}` is not newer than stable)"
    summary = "\n".join([
        f"### Upstream channels ({repo})",
        "",
        "| channel | upstream ref | release tag / label |",
        "|---|---|---|",
        f"| stable | `{stable or '-'}` ({tags[stable][:7] if stable else '-'}) | `{out['stable_release_tag'] or '-'}` |",
        f"| beta | {beta_line} | `{out['beta_release_tag'] or '-'}` |",
        f"| main | `main` ({main_sha[:7]}) | `{out['main_label']}` |",
        "",
    ])
    print(summary)
    with open(os.environ.get("GITHUB_OUTPUT", os.devnull), "a", encoding="utf-8") as f:
        f.writelines(f"{k}={v}\n" for k, v in out.items())
    with open(os.environ.get("GITHUB_STEP_SUMMARY", os.devnull), "a", encoding="utf-8") as f:
        f.write(summary + "\n")
    for k, v in out.items():
        print(f"{k}={v}")


if __name__ == "__main__":
    main()
