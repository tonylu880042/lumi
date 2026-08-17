import hashlib
import pathlib
import tempfile
import unittest
from dataclasses import replace
from types import SimpleNamespace

import numpy as np

from Tools.ModelConversion.build_yunet_coreml import (
    YUNET_INPUT_NAME,
    YUNET_INPUT_DTYPE,
    YUNET_INPUT_LAYOUT,
    YUNET_INPUT_NORMALIZATION,
    YUNET_INPUT_SHAPE,
    YUNET_INPUT_VALUE_RANGE,
    YUNET_DIRECTORY_LICENSE,
    YUNET_MODEL_BYTE_COUNT,
    YUNET_MODEL_PATH,
    YUNET_MODEL_SHA256,
    YUNET_MODEL_URL,
    YUNET_OUTPUT_NAMES,
    YUNET_OUTPUT_SPECS,
    YUNET_REVISION,
    YUNET_TENSOR_FLOAT32,
    YUNET_TAG,
    ConversionMetrics,
    OutputParityMetrics,
    calculate_output_parity,
    sha256_file,
    validate_raw_graph_contract,
    validate_conversion_metrics,
    verify_source_model,
    _coreml_output_types,
)


ONNX_TENSOR_FLOAT32 = 1


class YuNetCoreMLBuildTests(unittest.TestCase):
    def test_coreml_output_types_let_converter_infer_shapes(self) -> None:
        calls: list[dict[str, object]] = []

        class FakeCoreMLTools:
            @staticmethod
            def TensorType(**kwargs: object) -> dict[str, object]:
                calls.append(kwargs)
                return kwargs

        output_types = _coreml_output_types(FakeCoreMLTools, np.float32)

        self.assertEqual(len(output_types), len(YUNET_OUTPUT_SPECS))
        self.assertEqual(
            [item["name"] for item in calls],
            list(YUNET_OUTPUT_NAMES),
        )
        for call in calls:
            self.assertEqual(call["dtype"], np.float32)
            self.assertNotIn("shape", call)

    def test_source_manifest_is_pinned_to_official_lfs_object(self) -> None:
        self.assertEqual(YUNET_TAG, "4.10.0")
        self.assertEqual(
            YUNET_REVISION,
            "f88e9b2bafd21f1cad242fb5af6d78f2bcba16a3",
        )
        self.assertEqual(
            YUNET_MODEL_PATH,
            "models/face_detection_yunet/face_detection_yunet_2023mar.onnx",
        )
        self.assertEqual(YUNET_MODEL_BYTE_COUNT, 232_589)
        self.assertEqual(YUNET_DIRECTORY_LICENSE, "MIT")
        self.assertEqual(
            YUNET_MODEL_SHA256,
            "8f2383e4dd3cfbb4553ea8718107fc0423210dc964f9f4280604804ed2552fa4",
        )
        self.assertEqual(
            YUNET_MODEL_URL,
            "https://media.githubusercontent.com/media/opencv/opencv_zoo/"
            "4.10.0/models/face_detection_yunet/"
            "face_detection_yunet_2023mar.onnx",
        )

    def test_raw_graph_contract_names_input_and_outputs(self) -> None:
        self.assertEqual(YUNET_INPUT_NAME, "input")
        self.assertEqual(YUNET_INPUT_SHAPE, (1, 3, 640, 640))
        self.assertEqual(YUNET_INPUT_DTYPE, "float32")
        self.assertEqual(YUNET_TENSOR_FLOAT32, 1)
        self.assertEqual(YUNET_INPUT_LAYOUT, "BGR")
        self.assertEqual(YUNET_INPUT_VALUE_RANGE, (0.0, 255.0))
        self.assertIsNone(YUNET_INPUT_NORMALIZATION)
        self.assertEqual(
            YUNET_OUTPUT_NAMES,
            (
                "cls_8",
                "cls_16",
                "cls_32",
                "obj_8",
                "obj_16",
                "obj_32",
                "bbox_8",
                "bbox_16",
                "bbox_32",
                "kps_8",
                "kps_16",
                "kps_32",
            ),
        )
        self.assertEqual(
            tuple(spec.expected_shape for spec in YUNET_OUTPUT_SPECS),
            (
                (1, 6400, 1),
                (1, 1600, 1),
                (1, 400, 1),
                (1, 6400, 1),
                (1, 1600, 1),
                (1, 400, 1),
                (1, 6400, 4),
                (1, 1600, 4),
                (1, 400, 4),
                (1, 6400, 10),
                (1, 1600, 10),
                (1, 400, 10),
            ),
        )

    def test_sha256_file_hashes_exact_bytes(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            path = pathlib.Path(directory) / "artifact"
            path.write_bytes(b"curves-lumi-yunet")

            self.assertEqual(
                sha256_file(path),
                hashlib.sha256(b"curves-lumi-yunet").hexdigest(),
            )

    def test_source_verification_rejects_unpinned_bytes(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            path = pathlib.Path(directory) / "artifact"
            path.write_bytes(b"not-the-yunet-object")

            with self.assertRaises(ValueError):
                verify_source_model(path)

    def test_parity_compares_all_named_raw_outputs(self) -> None:
        reference = {
            spec.name: np.zeros(spec.expected_shape, dtype=np.float32)
            for spec in YUNET_OUTPUT_SPECS
        }
        converted = {name: value.copy() for name, value in reference.items()}
        converted["kps_16"][0, 0, 0] = 1.0e-3

        metrics = calculate_output_parity(reference, converted)

        self.assertEqual(tuple(metrics.outputs), YUNET_OUTPUT_NAMES)
        self.assertEqual(metrics.outputs["cls_8"].maximum_absolute_error, 0.0)
        self.assertAlmostEqual(
            metrics.outputs["kps_16"].maximum_absolute_error,
            1.0e-3,
            places=8,
        )
        with self.assertRaises(ValueError):
            validate_conversion_metrics(metrics)

    def test_parity_canonicalizes_mapping_outputs_by_name(self) -> None:
        reference = {
            spec.name: np.zeros(spec.expected_shape, dtype=np.float32)
            for spec in YUNET_OUTPUT_SPECS
        }
        reversed_reference = dict(reversed(list(reference.items())))

        metrics = calculate_output_parity(reversed_reference, reversed_reference)

        self.assertEqual(tuple(metrics.outputs), YUNET_OUTPUT_NAMES)

    def test_raw_graph_contract_accepts_exact_fake_graph(self) -> None:
        model = _fake_model()

        validate_raw_graph_contract(model)

    def test_raw_graph_contract_rejects_wrong_input_or_output_shape(self) -> None:
        cases = {
            "input shape": _fake_model(input_shape=(1, 3, 320, 320)),
            "output names": _fake_model(output_names=("wrong",) + YUNET_OUTPUT_NAMES[1:]),
            "output shape": _fake_model(output_shape_overrides={"kps_16": (1, 1600, 9)}),
            "input dtype": _fake_model(input_element_type=10),
            "output dtype": _fake_model(output_element_type_overrides={"kps_16": 10}),
        }

        for name, model in cases.items():
            with self.subTest(name=name):
                with self.assertRaises(ValueError):
                    validate_raw_graph_contract(model)

    def test_conversion_gate_rejects_non_finite_parity_metrics(self) -> None:
        valid_outputs = {
            spec.name: OutputParityMetrics(
                output_shape=spec.expected_shape,
                maximum_absolute_error=0.0,
                mean_absolute_error=0.0,
                cosine_similarity=1.0,
            )
            for spec in YUNET_OUTPUT_SPECS
        }

        for field in (
            "maximum_absolute_error",
            "mean_absolute_error",
            "cosine_similarity",
        ):
            for non_finite in (float("nan"), float("inf"), float("-inf")):
                with self.subTest(field=field, value=non_finite):
                    invalid = dict(valid_outputs)
                    invalid["cls_8"] = replace(
                        invalid["cls_8"],
                        **{field: non_finite},
                    )
                    with self.assertRaises(ValueError):
                        validate_conversion_metrics(
                            ConversionMetrics(outputs=invalid)
                        )

    def test_conversion_gate_requires_every_raw_output(self) -> None:
        metrics = ConversionMetrics(
            outputs={
                spec.name: OutputParityMetrics(
                    output_shape=spec.expected_shape,
                    maximum_absolute_error=0.0,
                    mean_absolute_error=0.0,
                    cosine_similarity=1.0,
                )
                for spec in YUNET_OUTPUT_SPECS
            }
        )

        validate_conversion_metrics(metrics)

        incomplete = ConversionMetrics(
            outputs={name: value for name, value in list(metrics.outputs.items())[:-1]}
        )
        with self.assertRaises(ValueError):
            validate_conversion_metrics(incomplete)

    def test_conversion_gate_rejects_shape_or_divergent_raw_output(self) -> None:
        valid_outputs = {
            spec.name: OutputParityMetrics(
                output_shape=spec.expected_shape,
                maximum_absolute_error=0.0,
                mean_absolute_error=0.0,
                cosine_similarity=1.0,
            )
            for spec in YUNET_OUTPUT_SPECS
        }

        invalid = dict(valid_outputs)
        invalid["kps_32"] = OutputParityMetrics(
            output_shape=(1, 400, 9),
            maximum_absolute_error=0.0,
            mean_absolute_error=0.0,
            cosine_similarity=1.0,
        )
        with self.assertRaises(ValueError):
            validate_conversion_metrics(ConversionMetrics(outputs=invalid))

        invalid = dict(valid_outputs)
        invalid["cls_8"] = OutputParityMetrics(
            output_shape=(1, 6400, 1),
            maximum_absolute_error=1.0e-3,
            mean_absolute_error=0.0,
            cosine_similarity=1.0,
        )
        with self.assertRaises(ValueError):
            validate_conversion_metrics(ConversionMetrics(outputs=invalid))

def _fake_value_info(
    name: str,
    shape: tuple[int, ...],
    elem_type: int = ONNX_TENSOR_FLOAT32,
):
    dimensions = [SimpleNamespace(dim_value=value) for value in shape]
    tensor_type = SimpleNamespace(
        elem_type=elem_type,
        shape=SimpleNamespace(dim=dimensions),
    )
    return SimpleNamespace(
        name=name,
        type=SimpleNamespace(tensor_type=tensor_type),
    )


def _fake_model(
    *,
    input_shape: tuple[int, ...] = YUNET_INPUT_SHAPE,
    input_element_type: int = ONNX_TENSOR_FLOAT32,
    output_names: tuple[str, ...] = YUNET_OUTPUT_NAMES,
    output_shape_overrides: dict[str, tuple[int, ...]] | None = None,
    output_element_type_overrides: dict[str, int] | None = None,
):
    output_shape_overrides = output_shape_overrides or {}
    output_element_type_overrides = output_element_type_overrides or {}
    outputs = [
        _fake_value_info(
            name,
            output_shape_overrides.get(name, spec.expected_shape),
            output_element_type_overrides.get(name, ONNX_TENSOR_FLOAT32),
        )
        for name, spec in zip(output_names, YUNET_OUTPUT_SPECS)
    ]
    graph = SimpleNamespace(
        initializer=[],
        input=[_fake_value_info(YUNET_INPUT_NAME, input_shape, input_element_type)],
        output=outputs,
    )
    return SimpleNamespace(graph=graph)


if __name__ == "__main__":
    unittest.main()
