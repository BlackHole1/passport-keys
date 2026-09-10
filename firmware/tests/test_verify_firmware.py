#!/usr/bin/env python3
"""Host tests for the protected firmware-layout parser."""

from __future__ import annotations

import hashlib
import importlib.util
import struct
import sys
import tempfile
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location(
    "verify_firmware", ROOT / "tools" / "verify_firmware.py"
)
assert SPEC and SPEC.loader
VERIFY = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = VERIFY
SPEC.loader.exec_module(VERIFY)


def sample_table() -> bytes:
    entries = (
        (1, 2, 0x9000, 0x6000, "nvs"),
        (1, 1, 0xF000, 0x1000, "phy_init"),
        (0, 0, 0x10000, 0x300000, "factory"),
        (1, 2, 0x356000, 0x4000, "cardid"),
    )
    raw = bytearray(b"\xff" * VERIFY.PARTITION_TABLE_SIZE)
    for index, (kind, subtype, offset, size, label) in enumerate(entries):
        VERIFY.ENTRY.pack_into(
            raw,
            index * VERIFY.ENTRY.size,
            0x50AA,
            kind,
            subtype,
            offset,
            size,
            label.encode().ljust(16, b"\0"),
            0,
        )
    marker = len(entries) * VERIFY.ENTRY.size
    struct.pack_into("<H", raw, marker, 0xEBEB)
    raw[marker + 16 : marker + 32] = hashlib.md5(raw[:marker]).digest()
    return bytes(raw)


class PartitionParserTest(unittest.TestCase):
    def test_parses_protected_layout_and_md5(self) -> None:
        partitions, found_md5 = VERIFY.parse_partition_table(sample_table())
        self.assertTrue(found_md5)
        self.assertEqual(partitions[-1].label, "cardid")
        self.assertEqual(partitions[-1].offset, VERIFY.CARDID_OFFSET)

    def test_rejects_bad_md5(self) -> None:
        raw = bytearray(sample_table())
        raw[28] ^= 1
        with self.assertRaisesRegex(ValueError, "MD5"):
            VERIFY.parse_partition_table(bytes(raw))


class ProtectedLayoutTest(unittest.TestCase):
    def test_layout_verification_accepts_current_partition_table(self) -> None:
        merged = bytearray(b"\xff" * (0x10000 + 1))
        merged[
            VERIFY.PARTITION_TABLE_OFFSET :
            VERIFY.PARTITION_TABLE_OFFSET + VERIFY.PARTITION_TABLE_SIZE
        ] = sample_table()
        merged[0x10000] = 0xE9

        with tempfile.TemporaryDirectory() as directory:
            build_dir = Path(directory)
            (build_dir / "FoloToy-AI-Passport.bin").write_bytes(b"\xe9")
            VERIFY.verify_protected_layout(bytes(merged), build_dir)

    def test_rejects_images_that_reach_cardid(self) -> None:
        VERIFY.verify_below_cardid(b"\xff" * VERIFY.CARDID_OFFSET)
        with self.assertRaisesRegex(ValueError, "cardid"):
            VERIFY.verify_below_cardid(b"\xff" * (VERIFY.CARDID_OFFSET + 1))


class AppDescriptionTest(unittest.TestCase):
    @staticmethod
    def merged_with_app_desc(version: bytes, magic: int = 0xABCD5432) -> bytes:
        merged = bytearray(b"\xff" * (VERIFY.APP_DESC_OFFSET + VERIFY.APP_DESC.size))
        VERIFY.APP_DESC.pack_into(
            merged, VERIFY.APP_DESC_OFFSET, magic, 0, b"\0" * 8, version.ljust(32, b"\0")
        )
        return bytes(merged)

    def test_reads_project_version(self) -> None:
        self.assertEqual(VERIFY.read_app_version(self.merged_with_app_desc(b"1.2.3")), "1.2.3")

    def test_rejects_missing_app_description(self) -> None:
        with self.assertRaisesRegex(ValueError, "esp_app_desc_t"):
            VERIFY.read_app_version(self.merged_with_app_desc(b"1.2.3", magic=0))


if __name__ == "__main__":
    unittest.main()
