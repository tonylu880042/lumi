#!/usr/bin/env python3
"""Build and numerically verify the pinned OpenCV Zoo SFace Core ML model.

This is a developer tool, not an App runtime dependency. It deliberately keeps
the upstream ONNX and generated Core ML package outside source control unless a
release owner separately approves the binary distribution strategy.
"""

from __future__ import annotations

import argparse
import dataclasses
import hashlib
import json
import pathlib
import urllib.request


SFACE_TAG = "4.10.0"
SFACE_REVISION = "f88e9b2bafd21f1cad242fb5af6d78f2bcba16a3"
SFACE_MODEL_URL = (
    "https://media.githubusercontent.com/media/opencv/opencv_zoo/"
    f"{SFACE_TAG}/models/face_recognition_sface/"
    "face_recognition_sface_2021dec.onnx"
)
SFACE_MODEL_SHA256 = (
    "0ba9fbfa01b5270c96627c4ef784da859931e02f04419c829e83484087c34e79"
)
SFACE_MODEL_BYTE_COUNT = 38_696_353
SFACE_INPUT_NAME = "data"
SFACE_OUTPUT_NAME = "fc1"
SFACE_COREML_OUTPUT_NAME = "embedding"
SFACE_INPUT_SHAPE = (1, 3, 112, 112)
SFACE_INPUT_CHANNEL_ORDER = "RGB"
SFACE_INPUT_DESCRIPTION = (
    "Float32 RGB tensor [1,3,112,112], values 0...255"
)
SFACE_OUTPUT_DIMENSION = 128


@dataclasses.dataclass(frozen=True)
class ConversionMetrics:
    output_dimension: int
    maximum_absolute_error: float
    mean_absolute_error: float
    cosine_similarity: float


def sha256_file(path: pathlib.Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def validate_conversion_metrics(metrics: ConversionMetrics) -> None:
    if metrics.output_dimension != SFACE_OUTPUT_DIMENSION:
        raise ValueError("Unexpected SFace embedding dimension")
    if metrics.maximum_absolute_error > 1.0e-5:
        raise ValueError("Core ML maximum absolute error exceeds conversion gate")
    if metrics.mean_absolute_error > 1.0e-6:
        raise ValueError("Core ML mean absolute error exceeds conversion gate")
    if metrics.cosine_similarity < 0.99999:
        raise ValueError("Core ML cosine similarity is below conversion gate")


def download_pinned_model(destination: pathlib.Path) -> None:
    destination.parent.mkdir(parents=True, exist_ok=True)
    request = urllib.request.Request(
        SFACE_MODEL_URL,
        headers={"User-Agent": "Curves-Lumi-SFace-Builder/1"},
    )
    with urllib.request.urlopen(request) as response, destination.open("wb") as output:
        while chunk := response.read(1024 * 1024):
            output.write(chunk)


def verify_source_model(path: pathlib.Path) -> None:
    if path.stat().st_size != SFACE_MODEL_BYTE_COUNT:
        raise ValueError("SFace source size does not match the pinned artifact")
    if sha256_file(path) != SFACE_MODEL_SHA256:
        raise ValueError("SFace source checksum does not match the pinned artifact")


def convert_and_verify(source: pathlib.Path, output: pathlib.Path) -> ConversionMetrics:
    # Heavy build-only dependencies stay out of import time so manifest tests can
    # run with the system Python without installing an ML toolchain.
    import coremltools as ct
    import numpy as np
    import onnx
    import onnxruntime as ort
    import torch
    from onnx2torch import convert

    onnx_model = onnx.load(source)
    initializer_names = {initializer.name for initializer in onnx_model.graph.initializer}
    graph_inputs = [item for item in onnx_model.graph.input if item.name not in initializer_names]
    graph_outputs = list(onnx_model.graph.output)
    if len(graph_inputs) != 1 or graph_inputs[0].name != SFACE_INPUT_NAME:
        raise ValueError("Unexpected SFace ONNX input")
    if len(graph_outputs) != 1 or graph_outputs[0].name != SFACE_OUTPUT_NAME:
        raise ValueError("Unexpected SFace ONNX output")

    torch_model = convert(onnx_model).eval()
    sample = np.random.default_rng(42).uniform(
        0,
        255,
        SFACE_INPUT_SHAPE,
    ).astype(np.float32)
    traced = torch.jit.trace(torch_model, torch.from_numpy(sample))

    coreml_model = ct.convert(
        traced,
        convert_to="mlprogram",
        inputs=[ct.TensorType(
            name=SFACE_INPUT_NAME,
            shape=SFACE_INPUT_SHAPE,
            dtype=np.float32,
        )],
        outputs=[ct.TensorType(name=SFACE_COREML_OUTPUT_NAME, dtype=np.float32)],
        minimum_deployment_target=ct.target.iOS17,
        compute_precision=ct.precision.FLOAT32,
    )
    coreml_model.author = "Curves Lumi build from OpenCV Zoo SFace"
    coreml_model.short_description = "SFace 128-dimensional face embedding"
    coreml_model.input_description[SFACE_INPUT_NAME] = SFACE_INPUT_DESCRIPTION
    coreml_model.output_description[SFACE_COREML_OUTPUT_NAME] = (
        "128-dimensional face embedding"
    )

    output.parent.mkdir(parents=True, exist_ok=True)
    coreml_model.save(output)

    onnx_output = ort.InferenceSession(
        str(source),
        providers=["CPUExecutionProvider"],
    ).run(None, {SFACE_INPUT_NAME: sample})[0].reshape(-1).astype(np.float64)
    coreml_output = np.asarray(
        ct.models.MLModel(str(output), compute_units=ct.ComputeUnit.CPU_ONLY).predict(
            {SFACE_INPUT_NAME: sample}
        )[SFACE_COREML_OUTPUT_NAME]
    ).reshape(-1).astype(np.float64)

    absolute_error = np.abs(onnx_output - coreml_output)
    metrics = ConversionMetrics(
        output_dimension=int(coreml_output.size),
        maximum_absolute_error=float(np.max(absolute_error)),
        mean_absolute_error=float(np.mean(absolute_error)),
        cosine_similarity=float(
            np.dot(onnx_output, coreml_output)
            / (np.linalg.norm(onnx_output) * np.linalg.norm(coreml_output))
        ),
    )
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
