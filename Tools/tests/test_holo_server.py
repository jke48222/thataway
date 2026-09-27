#!/usr/bin/env python3
"""Checks that the vision sidecar leaves no screen frame on disk.

The real model is 5.6 GB and not in the repo, so mlx_vlm is replaced with a
stub that records what `stream_generate` was handed. Everything else, the
stdin protocol, crop, resize and coordinate inverse, runs for real.

    python3 Tools/tests/test_holo_server.py
"""

import io
import json
import os
import sys
import tempfile
import types
import unittest
from pathlib import Path
from unittest import mock

from PIL import Image

TOOLS = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(TOOLS))


class FakeMLX:
    """Stand-in for the three mlx_vlm modules holo_server imports."""

    def __init__(self, accepts_pil=True):
        self.accepts_pil = accepts_pil
        self.seen = []           # what stream_generate got as image=
        self.existed = []        # whether a path image existed while in use

    def install(self):
        root = types.ModuleType("mlx_vlm")
        root.load = lambda path: ("model", "processor")
        root.stream_generate = self.stream_generate
        prompt_utils = types.ModuleType("mlx_vlm.prompt_utils")
        prompt_utils.apply_chat_template = lambda *a, **k: "prompt"
        utils = types.ModuleType("mlx_vlm.utils")
        utils.load_config = lambda path: {}
        utils.load_image = self.load_image
        root.prompt_utils, root.utils = prompt_utils, utils
        return mock.patch.dict(sys.modules, {
            "mlx_vlm": root,
            "mlx_vlm.prompt_utils": prompt_utils,
            "mlx_vlm.utils": utils,
        })

    def load_image(self, source):
        if isinstance(source, Image.Image) and not self.accepts_pil:
            raise ValueError("Unsupported image source type: Image")
        return source

    def stream_generate(self, model, processor, prompt, image=None, **kwargs):
        self.seen.append(image)
        if isinstance(image, str):
            self.existed.append(os.path.exists(image))
        yield types.SimpleNamespace(text='{"x": 100, "y": 50}')


class SidecarLeavesNothingOnDisk(unittest.TestCase):

    def setUp(self):
        self.dir = tempfile.TemporaryDirectory()
        self.root = Path(self.dir.name)
        self.models = self.root / "models"
        self.model = self.models / "holo"
        self.model.mkdir(parents=True)
        self.tmp = self.root / "tmp"
        self.tmp.mkdir()
        self.frame = self.root / "frame.png"
        Image.new("RGB", (400, 300), "white").save(self.frame)

    def tearDown(self):
        self.dir.cleanup()

    def run_server(self, fake, requests, legacy=False):
        if legacy:
            (self.models / ".holo_server_input.png").write_bytes(b"old frame")
        stdin = io.StringIO("".join(json.dumps(r) + "\n" for r in requests))
        stdout = io.StringIO()
        import holo_server
        with fake.install(), \
                mock.patch.object(sys, "argv", ["holo_server.py", str(self.model)]), \
                mock.patch.object(sys, "stdin", stdin), \
                mock.patch.object(sys, "stdout", stdout), \
                mock.patch.object(tempfile, "tempdir", str(self.tmp)), \
                mock.patch("signal.signal"):
            code = holo_server.main()
        self.assertEqual(code, 0)
        return [json.loads(l) for l in stdout.getvalue().splitlines()]

    def request(self, rid, crop=None):
        r = {"id": rid, "image": str(self.frame), "query": "the Play button"}
        if crop:
            r["crop"] = crop
        return r

    def assert_no_frames_left(self):
        self.assertEqual(sorted(p.name for p in self.models.iterdir()), ["holo"])
        self.assertEqual(list(self.tmp.iterdir()), [])

    def test_in_memory_path_never_writes_a_file(self):
        fake = FakeMLX(accepts_pil=True)
        out = self.run_server(fake, [self.request(1), self.request(2, [100, 50, 200, 100])])
        self.assertTrue(out[0]["ready"])
        self.assertEqual([o["id"] for o in out[1:]], [1, 2])
        self.assertTrue(all(isinstance(i, Image.Image) for i in fake.seen))
        self.assert_no_frames_left()

    def test_path_fallback_deletes_each_frame_after_generation(self):
        fake = FakeMLX(accepts_pil=False)
        out = self.run_server(fake, [self.request(1), self.request(2)])
        self.assertEqual([o["id"] for o in out[1:]], [1, 2])
        self.assertTrue(all(isinstance(i, str) for i in fake.seen))
        self.assertEqual(fake.existed, [True, True])
        for path in fake.seen:
            self.assertEqual(Path(path).parent, self.tmp)
            self.assertFalse(os.path.exists(path))
        self.assert_no_frames_left()

    def test_path_fallback_deletes_frame_when_generation_raises(self):
        fake = FakeMLX(accepts_pil=False)

        def boom(*a, image=None, **k):
            fake.seen.append(image)
            raise RuntimeError("metal out of memory")
            yield  # pragma: no cover

        fake.stream_generate = boom
        out = self.run_server(fake, [self.request(1)])
        self.assertIn("RuntimeError", out[1]["error"])
        self.assertFalse(os.path.exists(fake.seen[0]))
        self.assert_no_frames_left()

    def test_frame_left_by_earlier_builds_is_removed_at_startup(self):
        self.run_server(FakeMLX(), [], legacy=True)
        self.assert_no_frames_left()

    def test_coordinates_still_map_back_to_the_original_frame(self):
        out = self.run_server(FakeMLX(), [self.request(1, [100, 50, 200, 100])])
        # The stub answers (100, 50) in resized pixels. Undoing the resize and
        # the crop must put that point inside the crop box of the full frame.
        self.assertGreaterEqual(out[1]["x"], 100)
        self.assertLessEqual(out[1]["x"], 300)
        self.assertGreaterEqual(out[1]["y"], 50)
        self.assertLessEqual(out[1]["y"], 150)

    def test_importing_the_sidecar_writes_no_bytecode(self):
        import holo_server  # noqa: F401
        self.assertTrue(sys.dont_write_bytecode)


if __name__ == "__main__":
    unittest.main()
