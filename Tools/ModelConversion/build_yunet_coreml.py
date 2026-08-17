#!/usr/bin/env python3
"""Convert the pinned OpenCV Zoo YuNet detector to Core ML.

This is a developer-only conversion tool.  It intentionally does not decode
YuNet detections, apply confidence/NMS/top-k policy, or produce the 15-column
``FaceDetectorYN`` rows.  The Core ML artifact produced here exposes the same
12 raw tensors as the pinned ONNX graph so post-processing can be implemented
and reviewed in a separate slice.

The source graph contract is the OpenCV Zoo ``2023mar`` artifact used by
``FaceDetectorYN``:

* input ``input``: Float32 ``[1, 3, 640, 640]`` BGR values in ``0...255``;
  OpenCV's ``blobFromImage`` performs no additional normalization;
* outputs ``cls_*``, ``obj_*``, ``bbox_*``, and ``kps_*`` at strides 8, 16,
  and 32, in the order declared below.

The true model is downloaded only when ``--download`` is explicitly passed.
The manifest constants come from the official Git LFS pointer and tag; source
verification always checks both byte count and SHA-256 before conversion.
"""

from __future__ import annotations

import argparse
import dataclasses
import hashlib
import json
import math
import pathlib
from collections.abc import Mapping, Sequence
from typing import Any
import urllib.request


YUNET_TAG = "4.10.0"
YUNET_REVISION = "f88e9b2bafd21f1cad242fb5af6d78f2bcba16a3"
YUNET_MODEL_PATH = (
    "models/face_detection_yunet/face_detection_yunet_2023mar.onnx"
)
YUNET_MODEL_URL = (
    "https://media.githubusercontent.com/media/opencv/opencv_zoo/"
    f"{YUNET_TAG}/{YUNET_MODEL_PATH}"
)
YUNET_MODEL_SHA256 = (
    "8f2383e4dd3cfbb4553ea8718107fc0423210dc964f9f4280604804ed2552fa4"
)
YUNET_MODEL_BYTE_COUNT = 232_589
YUNET_DIRECTORY_LICENSE = "MIT"

YUNET_INPUT_NAME = "input"
YUNET_INPUT_SHAPE = (1, 3, 640, 640)
YUNET_INPUT_DTYPE = "float32"
YUNET_INPUT_LAYOUT = "BGR"
YUNET_INPUT_VALUE_RANGE = (0.0, 255.0)
YUNET_INPUT_NORMALIZATION = None
# ONNX TensorProto.FLOAT has enum value 1.  Keep this numeric constant local so
# manifest/contract tests do not require the optional ONNX build dependency.
YUNET_TENSOR_FLOAT32 = 1


@dataclasses.dataclass(frozen=True)
class RawOutputSpec:
    """One raw YuNet output tensor in the ONNX/Core ML graph contract."""

    name: str
    stride: int
    channels: int

    @property
    def expected_shape(self) -> tuple[int, int, int]:
        _, _, height, width = YUNET_INPUT_SHAPE
        rows = height // self.stride
        cols = width // self.stride
        return (1, rows * cols, self.channels)


# OpenCV FaceDetectorYN forwards these tensors in four groups (all cls, all
# obj, all bbox, all keypoints), while each group is ordered by stride.
YUNET_OUTPUT_SPECS = (
    RawOutputSpec("cls_8", stride=8, channels=1),
    RawOutputSpec("cls_16", stride=16, channels=1),
    RawOutputSpec("cls_32", stride=32, channels=1),
    RawOutputSpec("obj_8", stride=8, channels=1),
    RawOutputSpec("obj_16", stride=16, channels=1),
    RawOutputSpec("obj_32", stride=32, channels=1),
    RawOutputSpec("bbox_8", stride=8, channels=4),
    RawOutputSpec("bbox_16", stride=16, channels=4),
    RawOutputSpec("bbox_32", stride=32, channels=4),
    RawOutputSpec("kps_8", stride=8, channels=10),
    RawOutputSpec("kps_16", stride=16, channels=10),
    RawOutputSpec("kps_32", stride=32, channels=10),
)
YUNET_OUTPUT_NAMES = tuple(spec.name for spec in YUNET_OUTPUT_SPECS)


# These are conversion parity gates, not detector confidence/NMS thresholds.
MAX_ABSOLUTE_ERROR = 1.0e-5
MEAN_ABSOLUTE_ERROR = 1.0e-6
MIN_COSINE_SIMILARITY = 0.99999


@dataclasses.dataclass(frozen=True)
class OutputParityMetrics:
    output_shape: tuple[int, ...]
    maximum_absolute_error: float
    mean_absolute_error: float
    cosine_similarity: float


@dataclasses.dataclass(frozen=True)
class ConversionMetrics:
    outputs: Mapping[str, OutputParityMetrics]


def sha256_file(path: pathlib.Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def download_pinned_model(destination: pathlib.Path) -> None:
    """Download the exact official model object into ``destination``."""

    destination.parent.mkdir(parents=True, exist_ok=True)
    request = urllib.request.Request(
        YUNET_MODEL_URL,
        headers={"User-Agent": "Curves-Lumi-YuNet-Builder/1"},
    )
    with urllib.request.urlopen(request) as response, destination.open("wb") as output:
        while chunk := response.read(1024 * 1024):
            output.write(chunk)


def verify_source_model(path: pathlib.Path) -> None:
    """Reject anything that is not the pinned YuNet LFS object."""

    if path.stat().st_size != YUNET_MODEL_BYTE_COUNT:
        raise ValueError("YuNet source size does not match the pinned artifact")
    if sha256_file(path) != YUNET_MODEL_SHA256:
        raise ValueError("YuNet source checksum does not match the pinned artifact")


def _shape_from_value_info(value_info: Any) -> tuple[int, ...]:
    """Read a static ONNX tensor shape without importing ONNX at module load."""

    try:
        dimensions = value_info.type.tensor_type.shape.dim
    except AttributeError as error:
        raise ValueError("ONNX value has no tensor shape") from error

    shape: list[int] = []
    for dimension in dimensions:
        value = int(getattr(dimension, "dim_value", 0))
        if value <= 0:
            raise ValueError("YuNet graph contract requires static tensor shapes")
        shape.append(value)
    return tuple(shape)


def _element_type_from_value_info(value_info: Any) -> int:
    """Read an ONNX tensor element type without importing ONNX."""

    try:
        return int(value_info.type.tensor_type.elem_type)
    except (AttributeError, TypeError, ValueError) as error:
        raise ValueError("YuNet graph value has no tensor element type") from error


def _validate_float32_value_info(value_info: Any, label: str) -> None:
    if _element_type_from_value_info(value_info) != YUNET_TENSOR_FLOAT32:
        raise ValueError(f"Unexpected YuNet {label} tensor dtype")


def validate_raw_graph_contract(onnx_model: Any) -> None:
    """Validate the raw ONNX graph before conversion.

    This checks names, static shapes, and Float32 tensor types.  It
    intentionally does not run inference or decode the detector outputs.
    """

    graph = onnx_model.graph
    initializer_names = {initializer.name for initializer in graph.initializer}
    graph_inputs = [item for item in graph.input if item.name not in initializer_names]
    if len(graph_inputs) != 1 or graph_inputs[0].name != YUNET_INPUT_NAME:
        raise ValueError("Unexpected YuNet ONNX input name")
    _validate_float32_value_info(graph_inputs[0], "input")
    if _shape_from_value_info(graph_inputs[0]) != YUNET_INPUT_SHAPE:
        raise ValueError("Unexpected YuNet ONNX input shape")

    graph_outputs = list(graph.output)
    if tuple(item.name for item in graph_outputs) != YUNET_OUTPUT_NAMES:
        raise ValueError("Unexpected YuNet ONNX output names or order")
    for value_info, spec in zip(graph_outputs, YUNET_OUTPUT_SPECS):
        _validate_float32_value_info(value_info, f"{spec.name} output")
        if _shape_from_value_info(value_info) != spec.expected_shape:
            raise ValueError(f"Unexpected YuNet shape for {spec.name}")


def _named_outputs(
    outputs: Mapping[str, Any] | Sequence[Any],
) -> dict[str, Any]:
    if isinstance(outputs, Mapping):
        named = dict(outputs)
    else:
        if len(outputs) != len(YUNET_OUTPUT_NAMES):
            raise ValueError("YuNet conversion must expose all 12 raw outputs")
        named = dict(zip(YUNET_OUTPUT_NAMES, outputs))

    if set(named) != set(YUNET_OUTPUT_NAMES):
        raise ValueError("YuNet raw output names or order do not match the contract")
    return named


def calculate_output_parity(
    onnx_outputs: Mapping[str, Any] | Sequence[Any],
    coreml_outputs: Mapping[str, Any] | Sequence[Any],
) -> ConversionMetrics:
    """Compare every named raw tensor; no detection rows are produced."""

    import numpy as np

    onnx_by_name = _named_outputs(onnx_outputs)
    coreml_by_name = _named_outputs(coreml_outputs)
    metrics: dict[str, OutputParityMetrics] = {}
    for spec in YUNET_OUTPUT_SPECS:
        onnx_value = np.asarray(onnx_by_name[spec.name])
        coreml_value = np.asarray(coreml_by_name[spec.name])
        if onnx_value.shape != spec.expected_shape:
            raise ValueError(f"Unexpected ONNX shape for {spec.name}")
        if coreml_value.shape != spec.expected_shape:
            raise ValueError(f"Unexpected Core ML shape for {spec.name}")

        onnx_flat = onnx_value.astype(np.float64).reshape(-1)
        coreml_flat = coreml_value.astype(np.float64).reshape(-1)
        absolute_error = np.abs(onnx_flat - coreml_flat)
        denominator = np.linalg.norm(onnx_flat) * np.linalg.norm(coreml_flat)
        if denominator == 0:
            cosine_similarity = 1.0 if np.array_equal(onnx_flat, coreml_flat) else 0.0
        else:
            cosine_similarity = float(np.dot(onnx_flat, coreml_flat) / denominator)
        metrics[spec.name] = OutputParityMetrics(
            output_shape=tuple(int(value) for value in onnx_value.shape),
            maximum_absolute_error=float(np.max(absolute_error)),
            mean_absolute_error=float(np.mean(absolute_error)),
            cosine_similarity=cosine_similarity,
        )
    return ConversionMetrics(outputs=metrics)


def validate_conversion_metrics(metrics: ConversionMetrics) -> None:
    """Enforce parity gates for all 12 raw output tensors."""

    if set(metrics.outputs) != set(YUNET_OUTPUT_NAMES):
        raise ValueError("Conversion metrics must include all raw YuNet outputs")
    for spec in YUNET_OUTPUT_SPECS:
        value = metrics.outputs[spec.name]
        if tuple(value.output_shape) != spec.expected_shape:
            raise ValueError(f"Unexpected converted shape for {spec.name}")
        if not math.isfinite(value.maximum_absolute_error):
            raise ValueError(f"{spec.name} maximum absolute error is not finite")
        if not math.isfinite(value.mean_absolute_error):
            raise ValueError(f"{spec.name} mean absolute error is not finite")
        if not math.isfinite(value.cosine_similarity):
            raise ValueError(f"{spec.name} cosine similarity is not finite")
        if value.maximum_absolute_error > MAX_ABSOLUTE_ERROR:
            raise ValueError(f"{spec.name} maximum absolute error exceeds gate")
        if value.mean_absolute_error > MEAN_ABSOLUTE_ERROR:
            raise ValueError(f"{spec.name} mean absolute error exceeds gate")
        if value.cosine_similarity < MIN_COSINE_SIMILARITY:
            raise ValueError(f"{spec.name} cosine similarity is below gate")


def _coreml_output_types(coremltools: Any, dtype: Any) -> list[Any]:
    """Declare raw output names while letting Core ML infer their shapes.

    coremltools 9 rejects an explicit ``shape`` on output ``TensorType``
    declarations.  The traced graph already carries each raw tensor shape, so
    Core ML must infer those dimensions from the graph instead.
    """

    return [
        coremltools.TensorType(name=spec.name, dtype=dtype)
        for spec in YUNET_OUTPUT_SPECS
    ]


def convert_and_verify(source: pathlib.Path, output: pathlib.Path) -> ConversionMetrics:
    """Convert and compare the raw YuNet graph using build-time dependencies."""

    # Heavy build-only dependencies stay out of import time so manifest and
    # contract tests run with the system Python and no model/toolchain.
    import coremltools as ct
    import numpy as np
    import onnx
    import onnxruntime as ort
    import torch
    from onnx2torch import convert

    onnx_model = onnx.load(source)
    validate_raw_graph_contract(onnx_model)
    torch_model = convert(onnx_model).eval()
    sample = np.random.default_rng(42).uniform(
        YUNET_INPUT_VALUE_RANGE[0],
        YUNET_INPUT_VALUE_RANGE[1],
        YUNET_INPUT_SHAPE,
    ).astype(np.float32)
    traced = torch.jit.trace(
        torch_model,
        torch.from_numpy(sample),
        strict=False,
    )

    coreml_model = ct.convert(
        traced,
        convert_to="mlprogram",
        inputs=[ct.TensorType(
            name=YUNET_INPUT_NAME,
            shape=YUNET_INPUT_SHAPE,
            dtype=np.float32,
        )],
        outputs=_coreml_output_types(ct, np.float32),
        minimum_deployment_target=ct.target.iOS17,
        compute_precision=ct.precision.FLOAT32,
    )
    coreml_model.author = "Curves Lumi build from OpenCV Zoo YuNet"
    coreml_model.short_description = "YuNet raw face-detection tensors"
    coreml_model.input_description[YUNET_INPUT_NAME] = (
        "Float32 BGR tensor [1,3,640,640], values 0...255; no normalization"
    )
    for spec in YUNET_OUTPUT_SPECS:
        coreml_model.output_description[spec.name] = (
            f"Raw YuNet {spec.name} tensor; no post-processing"
        )

    output.parent.mkdir(parents=True, exist_ok=True)
    coreml_model.save(output)

    onnx_results = ort.InferenceSession(
        str(source),
        providers=["CPUExecutionProvider"],
    ).run(list(YUNET_OUTPUT_NAMES), {YUNET_INPUT_NAME: sample})
    coreml_results = ct.models.MLModel(
        str(output),
        compute_units=ct.ComputeUnit.CPU_ONLY,
    ).predict({YUNET_INPUT_NAME: sample})
    metrics = calculate_output_parity(onnx_results, coreml_results)
    validate_conversion_metrics(metrics)
    return metrics


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--source", type=pathlib.Path, required=True)
    parser.add_argument("--output", type=pathlib.Path, required=True)
    parser.add_argument("--download", action="store_true")
    args = parser.parse_args()

    if args.download:
        download_pinned_model(args.source)
    verify_source_model(args.source)
    metrics = convert_and_verify(args.source, args.output)
    print(json.dumps(dataclasses.asdict(metrics), sort_keys=True))


if __name__ == "__main__":
    main()
