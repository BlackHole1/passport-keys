#!/usr/bin/env python3
"""Create the GitHub Release for RELEASE_TAG, or upload assets when it already exists.

Port of the create-github-release step in oomol-lab/oo-cli contrib/ci/release-workflow.ts
and release-steps.ts. Usage: github_release.py <asset>...
"""

from __future__ import annotations

import os
import subprocess
import sys
import urllib.error
import urllib.parse
import urllib.request
from typing import Sequence

DEFAULT_GITHUB_API_URL = "https://api.github.com"
GITHUB_API_VERSION = "2022-11-28"


def build_create_release_command(
    release_tag: str,
    previous_tag: str,
    target: str,
    assets: Sequence[str],
) -> list[str]:
    if release_tag == "":
        raise ValueError("RELEASE_TAG is required.")
    if target == "":
        raise ValueError("GITHUB_SHA is required.")
    if not assets:
        raise ValueError("At least one release asset is required.")

    command = [
        "gh",
        "release",
        "create",
        release_tag,
        *assets,
        "--target",
        target,
        "--title",
        release_tag,
        "--generate-notes",
    ]
    if previous_tag != "":
        command += ["--notes-start-tag", previous_tag]
    command.append("--latest")
    return command


def build_upload_release_assets_command(release_tag: str, assets: Sequence[str]) -> list[str]:
    if release_tag == "":
        raise ValueError("RELEASE_TAG is required.")
    if not assets:
        raise ValueError("At least one release asset is required.")
    return ["gh", "release", "upload", release_tag, *assets, "--clobber"]


def does_github_release_exist(
    repository: str,
    release_tag: str,
    token: str,
    api_url: str = DEFAULT_GITHUB_API_URL,
) -> bool:
    url = f"{api_url.rstrip('/')}/repos/{repository}/releases/tags/{urllib.parse.quote(release_tag, safe='')}"
    request = urllib.request.Request(
        url,
        headers={
            "Accept": "application/vnd.github+json",
            "Authorization": f"Bearer {token}",
            "X-GitHub-Api-Version": GITHUB_API_VERSION,
        },
    )
    try:
        with urllib.request.urlopen(request, timeout=15):
            return True
    except urllib.error.HTTPError as error:
        if error.code == 404:
            return False
        body = error.read().decode("utf-8", "replace")
        raise RuntimeError(f"GitHub API request failed: {error.code} {error.reason}\n{body}") from error


def read_required_env(name: str) -> str:
    value = os.environ.get(name, "")
    if value == "":
        raise ValueError(f"{name} is required.")
    return value


def main(assets: Sequence[str]) -> int:
    try:
        release_tag = read_required_env("RELEASE_TAG")
        token = os.environ.get("GH_TOKEN") or os.environ.get("GITHUB_TOKEN") or ""
        if token == "":
            raise ValueError("GH_TOKEN or GITHUB_TOKEN is required.")

        if does_github_release_exist(
            repository=read_required_env("GITHUB_REPOSITORY"),
            release_tag=release_tag,
            token=token,
            api_url=os.environ.get("GITHUB_API_URL", DEFAULT_GITHUB_API_URL),
        ):
            command = build_upload_release_assets_command(release_tag, assets)
        else:
            command = build_create_release_command(
                release_tag=release_tag,
                previous_tag=os.environ.get("PREVIOUS_TAG", ""),
                target=read_required_env("GITHUB_SHA"),
                assets=assets,
            )
    except (RuntimeError, ValueError, urllib.error.URLError) as error:
        print(f"ERROR: {error}", file=sys.stderr)
        return 1

    return subprocess.run(command, check=False).returncode


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
