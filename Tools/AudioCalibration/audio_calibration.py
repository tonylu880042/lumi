#!/usr/bin/env python3
"""Audit and normalize Lumi's bundled recorded voice clips.

The tool intentionally uses only the locally installed ffmpeg/ffprobe
commands and Python's standard library.  Normalization always reads from the
immutable source directory and validates every temporary output before any
bundle asset is replaced, so a second run cannot compound the gain.
"""

from __future__ import annotations

import argparse
import hashlib
import json
from pathlib import Path
import re
import shutil
import subprocess
import sys
import tempfile
import wave
from typing import Any


TARGET_LUFS = -18.0
MAX_TRUE_PEAK_DBTP = -1.5
LOUDNESS_TOLERANCE_LU = 0.5
REQUIRED_CODEC = "pcm_s16le"
REQUIRED_SAMPLE_RATE = 24_000
REQUIRED_CHANNELS = 1
REQUIRED_BITS_PER_SAMPLE = 16


class CalibrationError(RuntimeError):
    """Raised when an audio tool or calibration invariant fails."""


def _tool(name: str) -> str:
    path = shutil.which(name)
    if path is None:
        raise CalibrationError(f"required tool not found on PATH: {name}")
    return path


def _run(command: list[str]) -> subprocess.CompletedProcess[str]:
    try:
        return subprocess.run(command, check=True, capture_output=True, text=True)
    except subprocess.CalledProcessError as error:
        details = (error.stderr or error.stdout or "").strip()
        raise CalibrationError(
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
            "-select_streams",
            "a:0",
            "-show_entries",
            "stream=codec_name,sample_rate,channels,bits_per_sample",
            "-of",
            "json",
            str(path),
        ]
    )
    try:
        payload = json.loads(result.stdout)
        stream = payload["streams"][0]
        with wave.open(str(path), "rb") as source:
            frames = source.getnframes()
            sample_rate = source.getframerate()
            channels = source.getnchannels()
            width = source.getsampwidth() * 8
            compression = source.getcomptype()
        return {
            "codec_name": stream.get("codec_name"),
            "sample_rate": int(stream["sample_rate"]),
            "channels": int(stream["channels"]),
            "bits_per_sample": int(stream.get("bits_per_sample") or width),
            "frames": frames,
            "duration_seconds": frames / sample_rate,
            "compression": compression,
        }
    except (KeyError, TypeError, ValueError, json.JSONDecodeError, wave.Error) as error:
        raise CalibrationError(f"invalid WAV probe for {path}") from error


def _measure(path: Path) -> dict[str, float]:
    result = _run(
        [
            _tool("ffmpeg"),
            "-hide_banner",
            "-nostats",
            "-i",
            str(path),
            "-af",
            f"loudnorm=I={TARGET_LUFS}:TP={MAX_TRUE_PEAK_DBTP}:LRA=7:print_format=json",
            "-f",
            "null",
            "-",
        ]
    )
    candidates = [item for item in _json_objects(result.stderr) if "input_i" in item]
    if not candidates:
        raise CalibrationError(f"loudnorm did not emit measurements for {path}")
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
        raise CalibrationError(f"invalid loudnorm output for {path}") from error


def clip_report(path: Path, tolerance: float = LOUDNESS_TOLERANCE_LU) -> dict[str, Any]:
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
    if report["compression"] != "NONE":
        failures.append("WAV compression must be NONE")
    if abs(report["integrated_loudness_lufs"] - TARGET_LUFS) > tolerance:
        failures.append(f"integrated loudness must be {TARGET_LUFS} ± {tolerance} LUFS")
    if report["true_peak_dbTP"] > MAX_TRUE_PEAK_DBTP:
        failures.append(f"true peak must be <= {MAX_TRUE_PEAK_DBTP} dBTP")

    report["failures"] = failures
    report["passes"] = not failures
    return report


def audit(directory: Path, tolerance: float = LOUDNESS_TOLERANCE_LU) -> dict[str, Any]:
    directory = directory.resolve()
    paths = sorted(directory.glob("*.wav"))
    if not paths:
        raise CalibrationError(f"no WAV assets found in {directory}")
    clips = [clip_report(path, tolerance) for path in paths]
    return {
        "directory": str(directory),
        "target_integrated_loudness_lufs": TARGET_LUFS,
        "target_max_true_peak_dbTP": MAX_TRUE_PEAK_DBTP,
        "integrated_loudness_tolerance_lu": tolerance,
        "clips": clips,
        "passes": all(clip["passes"] for clip in clips),
    }


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as source:
        for block in iter(lambda: source.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def verify_manifest(originals: Path, manifest_path: Path) -> list[dict[str, Any]]:
    originals = originals.resolve()
    manifest_path = manifest_path.resolve()
    try:
        payload = json.loads(manifest_path.read_text(encoding="utf-8"))
        entries = payload["files"]
        if payload["version"] != 1 or not isinstance(entries, list):
            raise ValueError
    except (OSError, KeyError, TypeError, ValueError, json.JSONDecodeError) as error:
        raise CalibrationError(f"invalid source manifest: {manifest_path}") from error

    if len(entries) != 8:
        raise CalibrationError("source manifest must contain exactly eight WAV files")
    names = [entry.get("file") for entry in entries]
    if any(not isinstance(name, str) or Path(name).name != name for name in names):
        raise CalibrationError("source manifest contains an invalid file name")
    if len(set(names)) != len(names):
        raise CalibrationError("source manifest contains duplicate file names")

    actual_wavs = {path.name for path in originals.glob("*.wav")}
    if actual_wavs != set(names):
        raise CalibrationError("source WAV directory does not match its manifest")

    verified: list[dict[str, Any]] = []
    for entry in sorted(entries, key=lambda item: item["file"]):
        path = originals / entry["file"]
        if sha256(path) != entry.get("sha256"):
            raise CalibrationError(f"source hash mismatch: {path.name}")
        probe = _probe(path)
        expected = {
            "frames": entry.get("frames"),
            "sample_rate": entry.get("sample_rate"),
            "channels": entry.get("channels"),
            "bytes_per_sample": entry.get("bytes_per_sample"),
        }
        actual = {
            "frames": probe["frames"],
            "sample_rate": probe["sample_rate"],
            "channels": probe["channels"],
            "bytes_per_sample": probe["bits_per_sample"] // 8,
        }
        if actual != expected:
            raise CalibrationError(f"source format/frame mismatch: {path.name}")
        verified.append({**entry, "path": path})
    return verified


def _normalize_asset(source: Path, destination: Path) -> None:
    first_pass = _measure(source)
    filter_expression = (
        f"loudnorm=I={TARGET_LUFS}:TP={MAX_TRUE_PEAK_DBTP}:LRA=7:"
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


def normalize(
    originals: Path,
    assets: Path,
    manifest: Path,
    tolerance: float = LOUDNESS_TOLERANCE_LU,
) -> dict[str, Any]:
    originals = originals.resolve()
    assets = assets.resolve()
    manifest = manifest.resolve()
    if originals == assets or originals in assets.parents or assets in originals.parents:
        raise CalibrationError("source originals and bundle assets must be separate")
    if not assets.is_dir():
        raise CalibrationError(f"bundle asset directory not found: {assets}")
    entries = verify_manifest(originals, manifest)

    with tempfile.TemporaryDirectory(
        prefix=".lumi-audio-calibration-", dir=str(assets.parent)
    ) as temporary_directory:
        temporary = Path(temporary_directory)
        outputs: list[tuple[Path, Path]] = []
        for entry in entries:
            source = entry["path"]
            output = temporary / entry["file"]
            _normalize_asset(source, output)
            report = clip_report(output, tolerance)
            if report["frames"] != entry["frames"]:
                raise CalibrationError(f"frame count changed during normalization: {source.name}")
            if not report["passes"]:
                raise CalibrationError(
                    f"normalized output failed validation for {source.name}: "
                    + "; ".join(report["failures"])
                )
            outputs.append((output, assets / entry["file"]))

        for output, destination in outputs:
            shutil.copyfile(output, destination)

    result = audit(assets, tolerance)
    result["source_manifest"] = str(manifest)
    result["source_sha256"] = {entry["file"]: entry["sha256"] for entry in entries}
    return result


def _parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description=__doc__)
    subparsers = parser.add_subparsers(dest="command", required=True)

    audit_parser = subparsers.add_parser("audit", help="measure existing WAV assets")
    audit_parser.add_argument("--assets", type=Path, required=True)
    audit_parser.add_argument("--tolerance", type=float, default=LOUDNESS_TOLERANCE_LU)
    audit_parser.add_argument("--check", action="store_true", help="fail if policy is not met")
    audit_parser.add_argument("--json-output", type=Path)

    normalize_parser = subparsers.add_parser(
        "normalize", help="normalize from immutable originals into bundle assets"
    )
    normalize_parser.add_argument("--originals", type=Path, required=True)
    normalize_parser.add_argument("--assets", type=Path, required=True)
    normalize_parser.add_argument("--manifest", type=Path, required=True)
    normalize_parser.add_argument("--tolerance", type=float, default=LOUDNESS_TOLERANCE_LU)
    normalize_parser.add_argument("--json-output", type=Path)
    return parser


def main(argv: list[str] | None = None) -> int:
    arguments = _parser().parse_args(argv)
    try:
        if arguments.command == "audit":
            report = audit(arguments.assets, arguments.tolerance)
        else:
            report = normalize(
                arguments.originals,
                arguments.assets,
                arguments.manifest,
                arguments.tolerance,
            )
    except CalibrationError as error:
        print(f"audio calibration failed: {error}", file=sys.stderr)
        return 2

    rendered = json.dumps(report, indent=2, sort_keys=True)
    if arguments.json_output:
        arguments.json_output.write_text(rendered + "\n", encoding="utf-8")
    print(rendered)
    if arguments.command == "audit" and arguments.check and not report["passes"]:
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
