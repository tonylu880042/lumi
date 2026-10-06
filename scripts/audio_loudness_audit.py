#!/usr/bin/env python3
"""Audit and normalize Lumi's bundled recorded voice clips.

The script deliberately uses the locally installed ffmpeg/ffprobe tools rather
than adding an audio dependency to the iOS runtime.  ``--normalize`` archives
the source WAVs first, writes verified temporary files beside them, and only
then replaces the bundle assets.  A second normalization run therefore cannot
silently compound the gain.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
import tempfile
from typing import Any


TARGET_LUFS = -18.0
TARGET_TRUE_PEAK = -1.5
LUFS_TOLERANCE = 0.35
REQUIRED_CODEC = "pcm_s16le"
REQUIRED_SAMPLE_RATE = 24_000
REQUIRED_CHANNELS = 1
REQUIRED_BITS_PER_SAMPLE = 16


class AudioToolError(RuntimeError):
    """Raised when an external audio tool cannot produce valid output."""


def _tool(name: str) -> str:
    path = shutil.which(name)
    if not path:
        raise AudioToolError(f"required tool not found on PATH: {name}")
    return path


def _run(command: list[str]) -> subprocess.CompletedProcess[str]:
    try:
        return subprocess.run(
            command,
            check=True,
            capture_output=True,
            text=True,
        )
    except subprocess.CalledProcessError as error:
        details = (error.stderr or error.stdout or "").strip()
        raise AudioToolError(
            f"command failed ({error.returncode}): {' '.join(command)}\n{details}"
        ) from error


def _json_objects(text: str) -> list[dict[str, Any]]:
    decoder = json.JSONDecoder()
    objects: list[dict[str, Any]] = []
    for match in re.finditer(r"\{", text):
        try:
            value, _ = decoder.raw_decode(text[match.start() :])
        except json.JSONDecodeError:
            continue
        if isinstance(value, dict):
            objects.append(value)
    return objects


def _probe(path: Path) -> dict[str, Any]:
    result = _run(
        [
            _tool("ffprobe"),
            "-v",
            "error",
            "-show_entries",
            "format=duration:stream=codec_name,sample_rate,channels,bits_per_sample",
            "-of",
            "json",
            str(path),
        ]
    )
    try:
        payload = json.loads(result.stdout)
        stream = payload["streams"][0]
        return {
            "duration_seconds": float(payload["format"]["duration"]),
            "codec_name": stream.get("codec_name"),
            "sample_rate": int(stream["sample_rate"]),
            "channels": int(stream["channels"]),
            "bits_per_sample": int(stream.get("bits_per_sample") or 0),
        }
    except (KeyError, TypeError, ValueError, json.JSONDecodeError) as error:
        raise AudioToolError(f"invalid ffprobe output for {path}") from error


def _measure(path: Path) -> dict[str, float]:
    result = _run(
        [
            _tool("ffmpeg"),
            "-hide_banner",
            "-nostats",
            "-i",
            str(path),
            "-af",
            f"loudnorm=I={TARGET_LUFS}:TP={TARGET_TRUE_PEAK}:LRA=7:print_format=json",
            "-f",
            "null",
            "-",
        ]
    )
    candidates = [item for item in _json_objects(result.stderr) if "input_i" in item]
    if not candidates:
        raise AudioToolError(f"loudnorm did not emit measurements for {path}")
    values = candidates[-1]
    try:
        return {
            "integrated_loudness_lufs": float(values["input_i"]),
            "true_peak_dbTP": float(values["input_tp"]),
            "loudness_range_lu": float(values["input_lra"]),
            "threshold_lufs": float(values["input_thresh"]),
            "target_offset_db": float(values["target_offset"]),
        }
    except (KeyError, TypeError, ValueError) as error:
        raise AudioToolError(f"invalid loudnorm output for {path}") from error


def _clip_report(path: Path, tolerance: float) -> dict[str, Any]:
    report: dict[str, Any] = {"file": path.name}
    report.update(_probe(path))
    report.update(_measure(path))
    failures: list[str] = []

    if report["codec_name"] != REQUIRED_CODEC:
        failures.append(f"codec must be {REQUIRED_CODEC}")
    if report["sample_rate"] != REQUIRED_SAMPLE_RATE:
        failures.append(f"sample rate must be {REQUIRED_SAMPLE_RATE} Hz")
    if report["channels"] != REQUIRED_CHANNELS:
        failures.append(f"channels must be {REQUIRED_CHANNELS}")
    if report["bits_per_sample"] != REQUIRED_BITS_PER_SAMPLE:
        failures.append(f"bits per sample must be {REQUIRED_BITS_PER_SAMPLE}")
    if abs(report["integrated_loudness_lufs"] - TARGET_LUFS) > tolerance:
        failures.append(f"integrated loudness must be {TARGET_LUFS} ± {tolerance} LUFS")
    if report["true_peak_dbTP"] > TARGET_TRUE_PEAK:
        failures.append(f"true peak must be <= {TARGET_TRUE_PEAK} dBTP")

    report["failures"] = failures
    report["passes"] = not failures
    return report


def audit(directory: Path, tolerance: float = LUFS_TOLERANCE) -> dict[str, Any]:
    paths = sorted(directory.glob("*.wav"))
    if not paths:
        raise AudioToolError(f"no WAV assets found in {directory}")
    clips = [_clip_report(path, tolerance) for path in paths]
    return {
        "directory": str(directory),
        "target_integrated_loudness_lufs": TARGET_LUFS,
        "target_max_true_peak_dbTP": TARGET_TRUE_PEAK,
        "integrated_loudness_tolerance_lu": tolerance,
        "clips": clips,
        "passes": all(clip["passes"] for clip in clips),
    }


def _sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as source:
        for block in iter(lambda: source.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def _normalize_asset(source: Path, destination: Path) -> None:
    first_pass = _measure(source)
    filter_expression = (
        f"loudnorm=I={TARGET_LUFS}:TP={TARGET_TRUE_PEAK}:LRA=7:"
        f"measured_I={first_pass['integrated_loudness_lufs']}:"
        f"measured_TP={first_pass['true_peak_dbTP']}:"
        f"measured_LRA={first_pass['loudness_range_lu']}:"
        f"measured_thresh={first_pass['threshold_lufs']}:"
        f"offset={first_pass['target_offset_db']}:linear=true:print_format=summary"
    )
    _run(
        [
            _tool("ffmpeg"),
            "-hide_banner",
            "-loglevel",
            "error",
            "-y",
            "-i",
            str(source),
            "-af",
            filter_expression,
            "-ar",
            str(REQUIRED_SAMPLE_RATE),
            "-ac",
            str(REQUIRED_CHANNELS),
            "-c:a",
            REQUIRED_CODEC,
            "-map_metadata",
            "0",
            str(destination),
        ]
    )


def normalize(directory: Path, archive_directory: Path, tolerance: float) -> dict[str, Any]:
    directory = directory.resolve()
    archive_directory = archive_directory.resolve()
    paths = sorted(directory.glob("*.wav"))
    if not paths:
        raise AudioToolError(f"no WAV assets found in {directory}")
    if archive_directory == directory or directory in archive_directory.parents:
        raise AudioToolError("archive directory must be outside the asset directory")
    archive_directory.mkdir(parents=True, exist_ok=False)

    for source in paths:
        destination = archive_directory / source.name
        shutil.copy2(source, destination)
        if _sha256(source) != _sha256(destination):
            raise AudioToolError(f"archive hash mismatch for {source.name}")

    temporary_files: list[tuple[Path, Path]] = []
    try:
        for source in paths:
            with tempfile.NamedTemporaryFile(
                dir=directory,
                prefix=f".{source.stem}.",
                suffix=".normalized.wav",
                delete=False,
            ) as temporary:
                temporary_path = Path(temporary.name)
            _normalize_asset(source, temporary_path)
            report = _clip_report(temporary_path, tolerance)
            if not report["passes"]:
                raise AudioToolError(
                    f"normalized output failed validation for {source.name}: "
                    + "; ".join(report["failures"])
                )
            temporary_files.append((source, temporary_path))

        for source, temporary_path in temporary_files:
            os.replace(temporary_path, source)
    finally:
        for _, temporary_path in temporary_files:
            temporary_path.unlink(missing_ok=True)

    result = audit(directory, tolerance)
    result["archive_directory"] = str(archive_directory)
    result["archive_sha256"] = {
        path.name: _sha256(path) for path in sorted(archive_directory.glob("*.wav"))
    }
    return result


def _arguments() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("directory", type=Path, help="directory containing WAV assets")
    parser.add_argument(
        "--check",
        action="store_true",
        help="return exit status 1 if the assets fail the loudness/format policy",
    )
    parser.add_argument(
        "--normalize",
        action="store_true",
        help="archive originals and replace assets with verified normalized WAVs",
    )
    parser.add_argument(
        "--archive-dir",
        type=Path,
        help="new directory in which --normalize stores the original WAVs",
    )
    parser.add_argument(
        "--json-output",
        type=Path,
        help="write the JSON audit report to this path",
    )
    parser.add_argument(
        "--tolerance",
        type=float,
        default=LUFS_TOLERANCE,
        help=f"allowed integrated-loudness error in LU (default: {LUFS_TOLERANCE})",
    )
    arguments = parser.parse_args()
    if arguments.normalize and arguments.archive_dir is None:
        parser.error("--normalize requires --archive-dir")
    if arguments.normalize and arguments.check:
        parser.error("choose either --normalize or --check")
    return arguments


def main() -> int:
    arguments = _arguments()
    try:
        if arguments.normalize:
            report = normalize(arguments.directory, arguments.archive_dir, arguments.tolerance)
        else:
            report = audit(arguments.directory, arguments.tolerance)
    except AudioToolError as error:
        print(f"audio loudness audit failed: {error}", file=sys.stderr)
        return 2

    rendered = json.dumps(report, indent=2, sort_keys=True)
    if arguments.json_output:
        arguments.json_output.write_text(rendered + "\n", encoding="utf-8")
    print(rendered)
    if arguments.check and not report["passes"]:
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
