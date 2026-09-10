#!/usr/bin/env python3
"""Tests for github_release.py, mirroring oo-cli release-steps and release-workflow behavior."""

from __future__ import annotations

import io
import os
import unittest
import urllib.error
from unittest import mock

import github_release
from github_release import (
    build_create_release_command,
    build_upload_release_assets_command,
    does_github_release_exist,
)


def http_error(code: int, reason: str) -> urllib.error.HTTPError:
    return urllib.error.HTTPError("https://api.github.com", code, reason, {}, io.BytesIO(b"{}"))


class ReleaseCommandTest(unittest.TestCase):
    def test_creates_a_release_with_notes_from_the_previous_tag(self) -> None:
        self.assertEqual(
            build_create_release_command(
                release_tag="v1.2.4",
                previous_tag="v1.2.3",
                target="abc123",
                assets=["dist/a.zip", "dist/SHA256SUMS"],
            ),
            [
                "gh", "release", "create", "v1.2.4", "dist/a.zip", "dist/SHA256SUMS",
                "--target", "abc123", "--title", "v1.2.4", "--generate-notes",
                "--notes-start-tag", "v1.2.3", "--latest",
            ],
        )

    def test_omits_the_notes_start_tag_for_the_first_release(self) -> None:
        command = build_create_release_command(release_tag="v0.0.1", previous_tag="", target="abc123", assets=["a.bin"])
        self.assertNotIn("--notes-start-tag", command)
        self.assertEqual(command[-1], "--latest")

    def test_rejects_missing_inputs(self) -> None:
        with self.assertRaisesRegex(ValueError, "RELEASE_TAG is required."):
            build_create_release_command(release_tag="", previous_tag="", target="abc123", assets=["a.bin"])
        with self.assertRaisesRegex(ValueError, "GITHUB_SHA is required."):
            build_create_release_command(release_tag="v1.0.0", previous_tag="", target="", assets=["a.bin"])
        with self.assertRaisesRegex(ValueError, "At least one release asset is required."):
            build_upload_release_assets_command(release_tag="v1.0.0", assets=[])

    def test_uploads_assets_with_clobber_when_the_release_exists(self) -> None:
        self.assertEqual(
            build_upload_release_assets_command(release_tag="v1.2.4", assets=["a.zip"]),
            ["gh", "release", "upload", "v1.2.4", "a.zip", "--clobber"],
        )


class ReleaseExistsTest(unittest.TestCase):
    def test_returns_true_for_an_existing_release(self) -> None:
        response = mock.MagicMock()
        response.__enter__.return_value = response
        with mock.patch("github_release.urllib.request.urlopen", return_value=response) as urlopen:
            self.assertTrue(does_github_release_exist("owner/repo", "v1.2.3", "token"))
        request = urlopen.call_args.args[0]
        self.assertEqual(request.full_url, "https://api.github.com/repos/owner/repo/releases/tags/v1.2.3")
        self.assertEqual(request.get_header("Authorization"), "Bearer token")

    def test_returns_false_for_404(self) -> None:
        with mock.patch("github_release.urllib.request.urlopen", side_effect=http_error(404, "Not Found")):
            self.assertFalse(does_github_release_exist("owner/repo", "v1.2.3", "token"))

    def test_raises_for_other_http_errors(self) -> None:
        with mock.patch("github_release.urllib.request.urlopen", side_effect=http_error(500, "Server Error")):
            with self.assertRaisesRegex(RuntimeError, "GitHub API request failed: 500"):
                does_github_release_exist("owner/repo", "v1.2.3", "token")


class MainTest(unittest.TestCase):
    ENV = {
        "RELEASE_TAG": "v1.2.4",
        "PREVIOUS_TAG": "v1.2.3",
        "GITHUB_SHA": "abc123",
        "GITHUB_REPOSITORY": "owner/repo",
        "GH_TOKEN": "token",
    }

    def run_main(self, release_exists: bool) -> list[str]:
        with mock.patch.dict(os.environ, self.ENV, clear=True), \
                mock.patch.object(github_release, "does_github_release_exist", return_value=release_exists), \
                mock.patch.object(github_release.subprocess, "run") as run:
            run.return_value.returncode = 0
            self.assertEqual(github_release.main(["a.zip"]), 0)
        return run.call_args.args[0]

    def test_creates_the_release_when_missing(self) -> None:
        self.assertEqual(self.run_main(release_exists=False)[:4], ["gh", "release", "create", "v1.2.4"])

    def test_uploads_to_an_existing_release(self) -> None:
        self.assertEqual(self.run_main(release_exists=True)[:4], ["gh", "release", "upload", "v1.2.4"])

    def test_fails_without_a_token(self) -> None:
        env = {key: value for key, value in self.ENV.items() if key != "GH_TOKEN"}
        with mock.patch.dict(os.environ, env, clear=True), mock.patch("sys.stderr", new=io.StringIO()):
            self.assertEqual(github_release.main(["a.zip"]), 1)


if __name__ == "__main__":
    unittest.main()
