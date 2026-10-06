#!/usr/bin/env python3
"""Regression checks for the offline recorded-voice asset policy."""

from __future__ import annotations

import importlib.util
from pathlib import Path
import unittest


ROOT = Path(__file__).resolve().parents[1]
ASSET_DIRECTORY = ROOT / "Sources/LumiInfrastructure/Resources/RecordedVoice"
MODULE_SPEC = importlib.util.spec_from_file_location(
    "audio_loudness_audit", Path(__file__).with_name("audio_loudness_audit.py")
)
assert MODULE_SPEC and MODULE_SPEC.loader
MODULE = importlib.util.module_from_spec(MODULE_SPEC)
MODULE_SPEC.loader.exec_module(MODULE)


class RecordedVoiceAssetTests(unittest.TestCase):
    def test_all_bundled_clips_meet_loudness_and_format_policy(self) -> None:
        report = MODULE.audit(ASSET_DIRECTORY)
        self.assertTrue(report["passes"], report)
        self.assertEqual(len(report["clips"]), 8)
        self.assertEqual(
            {clip["codec_name"] for clip in report["clips"]}, {"pcm_s16le"}
        )
        self.assertEqual({clip["sample_rate"] for clip in report["clips"]}, {24000})
        self.assertEqual({clip["channels"] for clip in report["clips"]}, {1})

    def test_clip_names_and_durations_are_unchanged(self) -> None:
        report = MODULE.audit(ASSET_DIRECTORY)
        self.assertEqual(
            [clip["file"] for clip in report["clips"]],
            [
                "01-welcome.wav",
                "02-welcome.wav",
                "03-welcome.wav",
                "04-returning.wav",
                "05-returning.wav",
                "06-returning.wav",
                "07-goodbye.wav",
                "08-goodbye.wav",
            ],
        )
        self.assertEqual(
            [round(clip["duration_seconds"], 2) for clip in report["clips"]],
            [4.50, 3.75, 2.85, 2.55, 3.05, 3.35, 3.55, 2.75],
        )


if __name__ == "__main__":
    unittest.main()
