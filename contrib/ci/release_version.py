#!/usr/bin/env python3
"""Compute the next release version from git tags.

Port of oomol-lab/oo-cli contrib/ci/compute-release-version.ts and release-version.ts.
Reads EXPECTED_VERSION and VERSION_BUMP, then writes version, tag_name, and previous_tag
to GITHUB_OUTPUT (or prints JSON when GITHUB_OUTPUT is not set).
"""

from __future__ import annotations

import json
import os
import subprocess
import sys
from dataclasses import asdict, dataclass
from typing import Literal, Sequence

VersionBump = Literal["patch", "minor", "major"]


@dataclass(frozen=True)
class ReleaseVersion:
    version: str
    tag_name: str
    previous_tag: str


def is_stable_semver(version: str) -> bool:
    segments = version.split(".")
    return len(segments) == 3 and all(segment.isascii() and segment.isdigit() for segment in segments)


def parse_stable_tag(tag: str) -> str | None:
    if not tag.startswith("v"):
        return None
    version = tag[1:]
    return version if is_stable_semver(version) else None


def normalize_expected_version(expected_version: str) -> str:
    version = expected_version[1:] if expected_version.startswith("v") else expected_version
    if not is_stable_semver(version):
        raise ValueError("Expected version must use the X.Y.Z format.")
    return version


def find_latest_stable_tag(tags: Sequence[str]) -> str:
    """Return the first stable tag from a list sorted newest first."""
    for tag in tags:
        if parse_stable_tag(tag) is not None:
            return tag
    return ""


def bump_version(version: str, version_bump: VersionBump) -> str:
    segments = version.split(".")
    if len(segments) != 3:
        raise ValueError(f"Invalid stable version: {version}")
    major, minor, patch = (int(segment) for segment in segments)
    if version_bump == "major":
        return f"{major + 1}.0.0"
    if version_bump == "minor":
        return f"{major}.{minor + 1}.0"
    if version_bump == "patch":
        return f"{major}.{minor}.{patch + 1}"
    raise ValueError("Unsupported version bump.")


def compute_release_version(expected_version: str, version_bump: VersionBump, tags: Sequence[str]) -> ReleaseVersion:
    previous_tag = find_latest_stable_tag(tags)
    if expected_version == "":
        version = bump_version(previous_tag[1:] if previous_tag else "0.0.0", version_bump)
    else:
        version = normalize_expected_version(expected_version)

    tag_name = f"v{version}"
    if tag_name in tags:
        raise ValueError(f"Tag {tag_name} already exists.")
    return ReleaseVersion(version=version, tag_name=tag_name, previous_tag=previous_tag)


def format_github_output(result: ReleaseVersion) -> str:
    return f"version={result.version}\ntag_name={result.tag_name}\nprevious_tag={result.previous_tag}\n"


def read_version_bump(value: str | None) -> VersionBump:
    if value == "patch" or value == "minor" or value == "major":
        return value
    raise ValueError(f"Unsupported version bump: {value or ''}")


def list_git_tags() -> list[str]:
    result = subprocess.run(
        ["git", "tag", "-l", "v*", "--sort=-v:refname"],
        capture_output=True,
        text=True,
    )
    if result.returncode != 0:
        stderr = result.stderr.strip()
        raise RuntimeError(stderr or "Failed to list git tags.")
    return [tag.strip() for tag in result.stdout.splitlines() if tag.strip()]


def main() -> int:
    try:
        result = compute_release_version(
            expected_version=os.environ.get("EXPECTED_VERSION", "").strip(),
            version_bump=read_version_bump(os.environ.get("VERSION_BUMP")),
            tags=list_git_tags(),
        )
    except (RuntimeError, ValueError) as error:
        print(f"ERROR: {error}", file=sys.stderr)
        return 1

    output_path = os.environ.get("GITHUB_OUTPUT", "")
    if output_path == "":
        print(json.dumps(asdict(result), indent=2))
        return 0

    with open(output_path, "a", encoding="utf-8") as output:
        output.write(format_github_output(result))
    print(f"Release version: {result.version} (previous tag: {result.previous_tag or 'none'})")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
