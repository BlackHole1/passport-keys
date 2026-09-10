#!/usr/bin/env python3
"""Tests for release_version.py, mirroring oo-cli contrib/ci/compute-release-version.test.ts."""

from __future__ import annotations

import unittest

from release_version import (
    ReleaseVersion,
    bump_version,
    compute_release_version,
    find_latest_stable_tag,
    format_github_output,
    is_stable_semver,
    normalize_expected_version,
    parse_stable_tag,
    read_version_bump,
)


class ComputeReleaseVersionTest(unittest.TestCase):
    def test_validates_stable_semver_strings(self) -> None:
        self.assertTrue(is_stable_semver("1.2.3"))
        self.assertFalse(is_stable_semver("1.2"))
        self.assertFalse(is_stable_semver("1.2.3-beta.1"))
        self.assertFalse(is_stable_semver("1..3"))

    def test_parses_stable_tags_only(self) -> None:
        self.assertEqual(parse_stable_tag("v1.2.3"), "1.2.3")
        self.assertIsNone(parse_stable_tag("1.2.3"))
        self.assertIsNone(parse_stable_tag("v1.2.3-beta.1"))

    def test_normalizes_an_explicit_version_with_or_without_a_v_prefix(self) -> None:
        self.assertEqual(normalize_expected_version("1.2.3"), "1.2.3")
        self.assertEqual(normalize_expected_version("v1.2.3"), "1.2.3")

    def test_rejects_explicit_versions_that_are_not_stable_semver(self) -> None:
        with self.assertRaisesRegex(ValueError, "Expected version must use the X.Y.Z format."):
            normalize_expected_version("1.2")

    def test_finds_the_latest_stable_tag_from_a_sorted_tag_list(self) -> None:
        self.assertEqual(find_latest_stable_tag(["v2.0.0-beta.1", "v1.4.0", "v1.3.9"]), "v1.4.0")
        self.assertEqual(find_latest_stable_tag(["foo", "bar"]), "")

    def test_bumps_the_latest_stable_tag_when_no_explicit_version_is_provided(self) -> None:
        self.assertEqual(bump_version("1.2.3", "patch"), "1.2.4")
        self.assertEqual(bump_version("1.2.3", "minor"), "1.3.0")
        self.assertEqual(bump_version("1.2.3", "major"), "2.0.0")

    def test_computes_the_next_patch_version_from_existing_tags(self) -> None:
        self.assertEqual(
            compute_release_version(expected_version="", version_bump="patch", tags=["v1.2.3", "v1.2.2"]),
            ReleaseVersion(version="1.2.4", tag_name="v1.2.4", previous_tag="v1.2.3"),
        )

    def test_falls_back_to_0_0_1_when_there_are_no_existing_stable_tags(self) -> None:
        self.assertEqual(
            compute_release_version(expected_version="", version_bump="patch", tags=[]),
            ReleaseVersion(version="0.0.1", tag_name="v0.0.1", previous_tag=""),
        )

    def test_uses_the_explicit_version_when_provided(self) -> None:
        self.assertEqual(
            compute_release_version(expected_version="v2.0.0", version_bump="patch", tags=["v1.2.3"]),
            ReleaseVersion(version="2.0.0", tag_name="v2.0.0", previous_tag="v1.2.3"),
        )

    def test_rejects_existing_tags(self) -> None:
        with self.assertRaisesRegex(ValueError, "Tag v1.2.3 already exists."):
            compute_release_version(expected_version="1.2.3", version_bump="patch", tags=["v1.2.3"])

    def test_reads_the_version_bump_from_the_workflow_input(self) -> None:
        self.assertEqual(read_version_bump("patch"), "patch")
        with self.assertRaisesRegex(ValueError, "Unsupported version bump: prerelease"):
            read_version_bump("prerelease")

    def test_formats_github_outputs(self) -> None:
        self.assertEqual(
            format_github_output(ReleaseVersion(version="1.2.3", tag_name="v1.2.3", previous_tag="v1.2.2")),
            "version=1.2.3\ntag_name=v1.2.3\nprevious_tag=v1.2.2\n",
        )


if __name__ == "__main__":
    unittest.main()
