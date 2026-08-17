import pathlib
import tempfile
import unittest

from Tools.ModelConversion.build_sface_coreml import (
    SFACE_MODEL_SHA256,
    SFACE_INPUT_CHANNEL_ORDER,
    SFACE_INPUT_DESCRIPTION,
    SFACE_INPUT_SHAPE,
    SFACE_OUTPUT_DIMENSION,
    ConversionMetrics,
    sha256_file,
    validate_conversion_metrics,
)


class SFaceCoreMLBuildTests(unittest.TestCase):
    def test_official_sface_input_contract_is_rgb(self) -> None:
        self.assertEqual(SFACE_INPUT_CHANNEL_ORDER, "RGB")
        self.assertEqual(
            SFACE_INPUT_DESCRIPTION,
            "Float32 RGB tensor [1,3,112,112], values 0...255",
        )
        self.assertEqual(SFACE_INPUT_SHAPE, (1, 3, 112, 112))

    def test_source_manifest_is_pinned(self) -> None:
        self.assertEqual(
            SFACE_MODEL_SHA256,
            "0ba9fbfa01b5270c96627c4ef784da859931e02f04419c829e83484087c34e79",
        )
        self.assertEqual(SFACE_OUTPUT_DIMENSION, 128)

    def test_sha256_file_hashes_exact_bytes(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            path = pathlib.Path(directory) / "artifact"
            path.write_bytes(b"curves-lumi-sface")

            self.assertEqual(
                sha256_file(path),
                "03231d626cb19638c802fe2950b7d31fcfdc48d7e02c3f2383f68ad9d79cce7a",
            )

    def test_conversion_gate_accepts_verified_poc_metrics(self) -> None:
        validate_conversion_metrics(
            ConversionMetrics(
                output_dimension=128,
                maximum_absolute_error=1.5944242477416992e-6,
                mean_absolute_error=5.584515747614205e-7,
                cosine_similarity=0.9999999999985524,
            )
        )

    def test_conversion_gate_rejects_wrong_shape_or_divergent_output(self) -> None:
        invalid_metrics = (
            ConversionMetrics(127, 0.0, 0.0, 1.0),
            ConversionMetrics(128, 1.0e-3, 0.0, 1.0),
            ConversionMetrics(128, 0.0, 1.0e-4, 1.0),
            ConversionMetrics(128, 0.0, 0.0, 0.999),
        )

        for metrics in invalid_metrics:
            with self.subTest(metrics=metrics):
                with self.assertRaises(ValueError):
                    validate_conversion_metrics(metrics)


if __name__ == "__main__":
    unittest.main()
