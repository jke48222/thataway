#!/usr/bin/env python3
"""Checks what Tools/make-app.sh puts in the bundle, without building or signing.

The script is copied into a throwaway repo with `swift`, `security` and
`codesign` replaced by stubs on PATH, so nothing is compiled, no keychain is
read and nothing is signed. `plutil` runs for real (macOS only).

    python3 Tools/tests/test_make_app.py
"""

import json
import os
import shutil
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

TOOLS = Path(__file__).resolve().parent.parent

STUB_SWIFT = "#!/bin/sh\nexit 0\n"
STUB_CODESIGN = '#!/bin/sh\necho "$*" >> "$CODESIGN_LOG"\n'


def stub_security(identity):
    line = f'  1) ABCDEF "{identity}"' if identity else ""
    return f"#!/bin/sh\necho '{line}'\n"


@unittest.skipUnless(sys.platform == "darwin" and shutil.which("plutil"),
                     "make-app.sh is macOS only")
class MakeAppBundle(unittest.TestCase):

    def build(self, identity=None):
        self.dir = tempfile.TemporaryDirectory()
        self.addCleanup(self.dir.cleanup)
        root = Path(self.dir.name)
        repo, bin_dir = root / "repo", root / "bin"
        (repo / "Tools").mkdir(parents=True)
        (repo / ".build/release").mkdir(parents=True)
        bin_dir.mkdir()
        for f in ["make-app.sh", "Thataway.entitlements", *(
                p.name for p in TOOLS.glob("*.py"))]:
            shutil.copy(TOOLS / f, repo / "Tools" / f)
        (repo / ".build/release/ThatawayApp").write_text("binary")
        for name, body in [("swift", STUB_SWIFT), ("codesign", STUB_CODESIGN),
                           ("security", stub_security(identity))]:
            p = bin_dir / name
            p.write_text(body)
            p.chmod(0o755)
        log = root / "codesign.log"
        env = dict(os.environ, PATH=f"{bin_dir}:{os.environ['PATH']}",
                   CODESIGN_LOG=str(log))
        subprocess.run(["bash", "Tools/make-app.sh"], cwd=repo, env=env,
                       check=True, capture_output=True, text=True)
        self.repo = repo
        self.app = repo / "build/Thataway.app"
        self.codesign = log.read_text().splitlines()

    def test_sidecar_ships_in_resources_tools(self):
        # App.toolsDirectory looks here first; holo_server imports holo_bench.
        self.build()
        tools = self.app / "Contents/Resources/Tools"
        for name in ["holo_server.py", "holo_bench.py"]:
            self.assertEqual((tools / name).read_bytes(),
                             (TOOLS / name).read_bytes(), name)
        self.assertFalse((tools / "__pycache__").exists())

    def test_info_plist_is_valid_with_one_closing_tag(self):
        self.build()
        plist = self.app / "Contents/Info.plist"
        subprocess.run(["plutil", "-lint", str(plist)], check=True,
                       capture_output=True)
        self.assertEqual(plist.read_text().count("</plist>"), 1)
        ident = subprocess.run(
            ["plutil", "-extract", "CFBundleExecutable", "raw", str(plist)],
            check=True, capture_output=True, text=True).stdout.strip()
        self.assertTrue((self.app / "Contents/MacOS" / ident).exists())

    def test_developer_id_signs_hardened_runtime_with_audio_input(self):
        self.build(identity="Developer ID Application: Test (XYZ)")
        sign = next(l for l in self.codesign if "--sign" in l)
        self.assertIn("--options runtime", sign)
        self.assertIn("--entitlements Tools/Thataway.entitlements", sign)
        # The key contains dots, which `plutil -extract` reads as a key path.
        ent = json.loads(subprocess.run(
            ["plutil", "-convert", "json", "-o", "-",
             str(self.repo / "Tools/Thataway.entitlements")],
            check=True, capture_output=True, text=True).stdout)
        self.assertIs(ent.get("com.apple.security.device.audio-input"), True)

    def test_every_signing_branch_passes_the_entitlements(self):
        for identity in [None, "Apple Development: Test (XYZ)"]:
            with self.subTest(identity=identity):
                self.build(identity=identity)
                sign = next(l for l in self.codesign if "--sign" in l)
                self.assertIn("--entitlements Tools/Thataway.entitlements", sign)


if __name__ == "__main__":
    unittest.main()
