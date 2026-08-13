import importlib.util
import os
import unittest
from pathlib import Path
from unittest.mock import patch


def load_worker():
    path = Path(__file__).parents[1] / "worker" / "worker.py"
    spec = importlib.util.spec_from_file_location("dance_now_worker", path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


class WorkerHelperTests(unittest.TestCase):
    def test_metadata_uri(self):
        worker = load_worker()
        self.assertEqual(
            worker.metadata_uri("s3://bucket/results/clip.mp4"),
            "s3://bucket/results/clip.json",
        )

    def test_env_bool(self):
        worker = load_worker()
        with patch.dict(os.environ, {"OPTION": "yes"}):
            self.assertTrue(worker.env_bool("OPTION", False))
