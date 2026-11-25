#!/usr/bin/env python3
"""CI helpers. Subcommands:

  resolve                      upstream refs per channel, and whether each channel needs a build
  check-environment <name>     the environment exists and requires reviewers
  check-order <channel> <tag>  no newer release of the channel exists

GitHub API calls go through `gh api` (GH_TOKEN, GH_REPO). Tags are classified by name, not by
upstream's "prerelease" flag: upstream publishes some betas (1.1.0-beta2, 1.0.0-beta) as normal
releases.
"""

import json
import os
import re
import subprocess
import sys
import urllib.parse

STABLE_RE = re.compile(r"^(\d+)\.(\d+)\.(\d+)$")
BETA_RE = re.compile(r"^(\d+)\.(\d+)\.(\d+)-beta(\d*)$")
RELEASE_TAG_RE = re.compile(r"^v(.+)-(\d+)$")
NIGHTLY_TAG = "nightly"
CHANNELS = ("stable", "beta", "main")


class NotFound(Exception):
    pass


class ApiError(Exception):
    pass


def version_key(tag):
    m = STABLE_RE.match(tag)
    if m:
        return (int(m[1]), int(m[2]), int(m[3]), 1, 0)
    m = BETA_RE.match(tag)
    if m:
        return (int(m[1]), int(m[2]), int(m[3]), 0, int(m[4] or 0))
    return None


def gh_api(path):
    p = subprocess.run(["gh", "api", path], capture_output=True, text=True)
    if p.returncode != 0:
        if "HTTP 404" in p.stderr:
            raise NotFound(path)
        raise ApiError(f"gh api {path} failed: {p.stderr.strip()}")
    return json.loads(p.stdout)


def gh_list(path, key=None):
    sep = "&" if "?" in path else "?"
    items, page = [], 1
    while True:
        data = gh_api(f"{path}{sep}per_page=100&page={page}")
        batch = data[key] if key else data
        items += batch
        if len(batch) < 100:
            return items
        page += 1


def ls_remote(repo):
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
            if name.endswith("^{}"):
                tags[name[:-3]] = sha
            else:
                tags.setdefault(name, sha)
    return tags, main


def pick(rels, tags):
    """rels: [(tag, prerelease)]. Returns (stable, newest_beta, beta_or_None, warnings)."""
    warnings = []
    stable, beta = [], []
    for tag, pre in rels:
        if tag not in tags:
            warnings.append(f"release {tag} has no tag in the upstream repository; ignored")
        elif STABLE_RE.match(tag) and not pre:
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


def build_line(upstream_sha, builder_sha):
    return f"komorebi-build: upstream={upstream_sha} builder={builder_sha}"


def marker_name(channel, variant, upstream_sha, builder_sha):
    return f"built-{channel}-{variant}-{upstream_sha}-{builder_sha}"


def release_channel(release):
    tag = release["tag_name"]
    if tag == NIGHTLY_TAG:
        return "main"
    if not RELEASE_TAG_RE.match(tag):
        return None
    return "beta" if release["prerelease"] else "stable"


def already_built(channel, variant, upstream_sha, builder_sha, branch, run_id, artifacts, releases):
    """Reason string when this (channel, upstream, builder) was built or released before, else None.

    artifacts: the repo's artifacts named marker_name(...); releases: this repo's releases.
    """
    name = marker_name(channel, variant, upstream_sha, builder_sha)
    for a in artifacts:
        run = a.get("workflow_run") or {}
        # Same run id = "re-run all jobs", which must rebuild because it re-resolves.
        if (a["name"] == name and not a["expired"] and run.get("head_branch") == branch
                and run.get("head_sha") == builder_sha and str(run.get("id")) != str(run_id)):
            return f"built in run {run.get('id')} (artifacts until {a.get('expires_at', '?')})"
    line = build_line(upstream_sha, builder_sha)
    for r in releases:
        if not r.get("draft") and release_channel(r) == channel and line in (r.get("body") or ""):
            return f"already released as {r['tag_name']}"
    return None


def write_outputs(out, summary):
    with open(os.environ.get("GITHUB_OUTPUT", os.devnull), "a", encoding="utf-8") as f:
        f.writelines(f"{k}={v}\n" for k, v in out.items())
    with open(os.environ.get("GITHUB_STEP_SUMMARY", os.devnull), "a", encoding="utf-8") as f:
        f.write(summary + "\n")
    print(summary)
    for k, v in out.items():
        print(f"{k}={v}")


def cmd_resolve():
    upstream = os.environ["UPSTREAM_REPO"]
    repo = os.environ["GH_REPO"]
    n = os.environ["RUN_NUMBER"]
    run_id = os.environ["RUN_ID"]
    builder = os.environ["BUILDER_SHA"]
    branch = os.environ["BRANCH"]
    force = os.environ.get("FORCE") == "true"
    variant = "release" if os.environ.get("HAS_SIGNING_KEY") == "true" else "debug"

    tags, main_sha = ls_remote(upstream)
    if not main_sha:
        sys.exit(f"::error::upstream {upstream} has no main branch")
    rels = [(r["tag_name"], bool(r["prerelease"]))
            for r in gh_list(f"repos/{upstream}/releases") if not r.get("draft")]
    stable, newest_beta, beta, warnings = pick(rels, tags)
    for w in warnings:
        print(f"::warning::{w}")
    if not stable:
        print(f"::warning::upstream {upstream} has no stable (X.Y.Z) release; the stable channel is not built")

    own_releases = gh_list(f"repos/{repo}/releases")
    out = {"variant": variant, "upstream_stable": stable or "", "upstream_newest_beta": newest_beta or ""}
    rows = []
    for channel, utag, sha in (("stable", stable, tags.get(stable)), ("beta", beta, tags.get(beta)),
                               ("main", None, main_sha)):
        exists = channel == "main" or bool(utag)
        if not exists:
            ref = release_tag = label = version_name = marker = ""
        elif channel == "main":
            ref, release_tag = "refs/heads/main", ""
            label = version_name = f"main-{n}"
        else:
            ref, release_tag = f"refs/tags/{utag}", f"v{utag}-{n}"
            label, version_name = release_tag, release_tag[1:]
        reason = None
        if exists:
            marker = marker_name(channel, variant, sha, builder)
            arts = gh_list(f"repos/{repo}/actions/artifacts?name={urllib.parse.quote(marker)}", "artifacts")
            reason = already_built(channel, variant, sha, builder, branch, run_id, arts, own_releases)
            if reason and force:
                reason = f"forced rebuild ({reason})"
                build = True
            else:
                build = reason is None
        else:
            build = False
            reason = ("no beta newer than stable" if channel == "beta" else "no stable release")
        out.update({f"{channel}_ref": ref, f"{channel}_sha": sha or "", f"{channel}_release_tag": release_tag,
                    f"{channel}_label": label, f"{channel}_version_name": version_name,
                    f"{channel}_marker": marker, f"{channel}_build": "true" if build else "false"})
        shown = f"`{ref.split('/')[-1]}` ({sha[:7]})" if exists else "-"
        rows.append(f"| {channel} | {shown} | `{label or '-'}` | {'build' if build else 'skip'}: {reason or 'new'} |")

    summary = "\n".join([
        f"### Channels (upstream {upstream}, {variant} build of {builder[:7]})", "",
        "| channel | upstream | label | decision |", "|---|---|---|---|", *rows, ""])
    write_outputs(out, summary)


def check_environment(repo, name):
    """None when the environment requires reviewers, else an error message."""
    hint = (f"Create the environment '{name}' with required reviewers (Settings -> Environments) "
            "before releases can be approved.")
    try:
        env = gh_api(f"repos/{repo}/environments/{urllib.parse.quote(name)}")
    except NotFound:
        return f"Environment '{name}' does not exist; GitHub would create it unprotected and publish without approval. {hint}"
    except (ApiError, ValueError) as e:
        return f"Could not read environment '{name}' ({e}); not publishing. {hint}"
    for rule in env.get("protection_rules") or []:
        if rule.get("type") == "required_reviewers" and rule.get("reviewers"):
            return None
    return f"Environment '{name}' has no required reviewers, so it would publish without approval. {hint}"


def cmd_check_environment(name):
    err = check_environment(os.environ["GH_REPO"], name)
    if err:
        print(f"::error::{err}")
        sys.exit(1)
    print(f"Environment '{name}' requires reviewers")


def newer_release(channel, tag, releases):
    """The tag of an existing release that makes `tag` obsolete, or None."""
    m = RELEASE_TAG_RE.match(tag)
    if not m or version_key(m[1]) is None:
        raise ValueError(f"unexpected release tag {tag}")
    key = (version_key(m[1]), int(m[2]))
    for r in releases:
        other = r["tag_name"]
        om = RELEASE_TAG_RE.match(other)
        if r.get("draft") or other == tag or not om or version_key(om[1]) is None:
            continue
        okey = (version_key(om[1]), int(om[2]))
        ch = release_channel(r)
        if ch == channel and okey > key:
            return other
        if channel == "beta" and ch == "stable" and okey[0] > key[0]:
            return other
    return None


def cmd_check_order(channel, tag):
    newer = newer_release(channel, tag, gh_list(f"repos/{os.environ['GH_REPO']}/releases"))
    if newer:
        print(f"::error::Not publishing {tag}: the newer release {newer} already exists "
              "(this run was approved after a later one).")
        sys.exit(1)
    print(f"No release newer than {tag}")


def main(argv):
    try:
        if argv[:1] == ["resolve"] and len(argv) == 1:
            cmd_resolve()
        elif argv[:1] == ["check-environment"] and len(argv) == 2:
            cmd_check_environment(argv[1])
        elif argv[:1] == ["check-order"] and len(argv) == 3 and argv[1] in ("stable", "beta"):
            cmd_check_order(argv[1], argv[2])
        else:
            sys.exit(f"usage: {sys.argv[0]} resolve | check-environment <name> | check-order stable|beta <tag>")
    except ApiError as e:
        print(f"::error::{e}")
        sys.exit(1)


if __name__ == "__main__":
    main(sys.argv[1:])
