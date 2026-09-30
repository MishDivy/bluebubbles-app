import importlib.util
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest
from unittest.mock import patch
import zipfile


SPEC = importlib.util.spec_from_file_location("preview_artifact", Path(__file__).parents[1] / "prepare_preview_artifact.py")
artifact = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(artifact)


class PreviewArtifactTest(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.apk = self.root / "input.apk"
        with zipfile.ZipFile(self.apk, "w") as archive:
            archive.writestr("AndroidManifest.xml", b"offline manifest fixture")
            archive.writestr("lib/arm64-v8a/libapp.so", b"offline app fixture")
            archive.writestr("lib/arm64-v8a/libflutter.so", b"offline Flutter fixture")
        self.tools = self.root / "tools"
        self.tools.mkdir()
        for name in ("aapt", "apksigner", "zipalign"):
            (self.tools / name).touch()
        self.badging = "package: name='com.bluebubbles.messaging.divy' versionCode='1' versionName='2.1.1'\nnative-code: 'arm64-v8a'\n"
        self.signature_code = 1
        self.signature_output = "DOES NOT VERIFY\nERROR: Missing META-INF/MANIFEST.MF"
        self.source_commit = "a" * 40
        self.tool_calls = []

    def run_tool(self, tool, *args, check=True):
        self.tool_calls.append((Path(tool).name, args))
        if Path(tool).name == "aapt":
            return subprocess.CompletedProcess([], 0, self.badging, "")
        if Path(tool).name == "apksigner":
            return subprocess.CompletedProcess([], self.signature_code, self.signature_output, "")
        if Path(tool).name == "git":
            return subprocess.CompletedProcess([], 0, self.source_commit, "")
        if Path(tool).name == "zipalign" and "-c" not in args:
            shutil.copyfile(args[-2], args[-1])
        return subprocess.CompletedProcess([], 0, "", "")

    def test_identity_rejects_wrong_package_version_debug_or_abi(self):
        original = self.badging
        for badging in (original.replace(".divy", ""), original.replace("versionCode='1'", "versionCode='2'"),
                        original + "application-debuggable\n", original.replace("arm64-v8a", "x86_64")):
            with self.subTest(badging=badging), patch.object(artifact, "run_tool", self.run_tool):
                self.badging = badging
                with self.assertRaises(ValueError):
                    artifact.inspect_apk(self.apk, self.tools, 1)

    def test_signed_and_unexpected_verifier_failures_are_rejected(self):
        for code, output in ((0, "Verified"), (127, "tool missing"), (1, "unexpected failure")):
            self.signature_code, self.signature_output = code, output
            with self.subTest(code=code), patch.object(artifact, "run_tool", self.run_tool):
                with self.assertRaises(ValueError):
                    artifact.inspect_apk(self.apk, self.tools, 1)

    def test_missing_or_other_abi_native_libraries_are_rejected(self):
        with zipfile.ZipFile(self.apk, "a") as archive:
            archive.writestr("lib/x86_64/libapp.so", b"wrong ABI fixture")
        with self.assertRaises(ValueError):
            artifact.inspect_apk(self.apk, self.tools, 1)
        with zipfile.ZipFile(self.apk, "w") as archive:
            archive.writestr("AndroidManifest.xml", b"offline manifest fixture")
        with self.assertRaises(ValueError):
            artifact.inspect_apk(self.apk, self.tools, 1)

    def test_corrupt_zip_and_embedded_certificate_are_rejected(self):
        with zipfile.ZipFile(self.apk, "a") as archive:
            archive.writestr("META-INF/CERT.RSA", b"offline certificate fixture")
        with self.assertRaises(ValueError):
            artifact.inspect_apk(self.apk, self.tools, 1)
        self.apk.write_bytes(b"not an APK")
        with self.assertRaises(zipfile.BadZipFile):
            artifact.inspect_apk(self.apk, self.tools, 1)

    def test_package_metadata_and_checksum_after_alignment(self):
        output = self.root / "output"
        with patch.object(artifact, "run_tool", self.run_tool), patch.dict(os.environ, {}, clear=True):
            metadata = artifact.prepare_artifact(self.apk, self.tools, 1, output)
        self.assertEqual(metadata, json.loads((output / "candidate.json").read_text()))
        self.assertIn(metadata["sha256"], (output / "SHA256SUMS").read_text())
        self.assertEqual(metadata["sourceCommit"], self.source_commit)
        self.assertTrue(metadata["unsigned"])
        self.assertTrue((output / metadata["filename"]).is_file())
        self.assertEqual(sum(name == "zipalign" for name, _ in self.tool_calls), 2)

    def test_commit_mismatch_and_existing_output_are_rejected(self):
        with patch.object(artifact, "run_tool", self.run_tool), patch.dict(os.environ, {"GITHUB_SHA": "b" * 40}):
            with self.assertRaises(ValueError):
                artifact.prepare_artifact(self.apk, self.tools, 1, self.root / "output")
        with patch.object(artifact, "run_tool", self.run_tool), patch.dict(os.environ, {}, clear=True):
            with self.assertRaises(FileExistsError):
                artifact.prepare_artifact(self.apk, self.tools, 1, self.root)


if __name__ == "__main__":
    unittest.main()
