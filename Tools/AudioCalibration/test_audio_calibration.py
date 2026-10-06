#!/usr/bin/env python3
"""Focused checks for the recorded-voice calibration deliverable."""

from __future__ import annotations

import json
from pathlib import Path
import sys
import unittest


HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[1]
sys.path.insert(0, str(HERE))

import audio_calibration  # noqa: E402


ASSETS = ROOT / "Sources/LumiInfrastructure/Resources/RecordedVoice"
ORIGINALS = HERE / "originals"
MANIFEST = ORIGINALS / "manifest.json"


class RecordedVoiceCalibrationTests(unittest.TestCase):
    def test_bundled_assets_meet_calibration_policy(self) -> None:
        report = audio_calibration.audit(ASSETS)

        self.assertTrue(report["passes"], report)
        self.assertEqual(len(report["clips"]), 8)

    def test_bundled_assets_preserve_original_wav_contract(self) -> None:
        manifest = audio_calibration.verify_manifest(ORIGINALS, MANIFEST)
        report = audio_calibration.audit(ASSETS)
        actual = {clip["file"]: clip for clip in report["clips"]}

        self.assertEqual(set(actual), {entry["file"] for entry in manifest})
        for entry in manifest:
            clip = actual[entry["file"]]
            self.assertEqual(clip["frames"], entry["frames"])
            self.assertEqual(clip["sample_rate"], entry["sample_rate"])
            self.assertEqual(clip["channels"], entry["channels"])
            self.assertEqual(
                clip["bits_per_sample"] // 8, entry["bytes_per_sample"]
            )

    def test_manifest_is_stable_json_with_sha256_sources(self) -> None:
        payload = json.loads(MANIFEST.read_text(encoding="utf-8"))

        self.assertEqual(payload["version"], 1)
        self.assertEqual(len(payload["files"]), 8)
        self.assertTrue(all(len(entry["sha256"]) == 64 for entry in payload["files"]))


if __name__ == "__main__":
    unittest.main()
