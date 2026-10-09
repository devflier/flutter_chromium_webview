import hashlib
import importlib.util
import io
from pathlib import Path
import tarfile
import tempfile
import unittest
from unittest.mock import patch


def load(name):
    path = Path(__file__).resolve().parents[1] / "scripts" / (name + ".py")
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


prepare = load("prepare_cef")
embed = load("embed_cef")


class DistributionTests(unittest.TestCase):
    def test_clean_runner_build_compiles_host_without_a_prebuilt_host_app(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / "cef").mkdir()
            (root / "cef/config.json").write_text('{"arch":"arm64"}')
            (root / "Runner.app/Contents").mkdir(parents=True)
            environment = {"ARCHS": "arm64", "TARGET_BUILD_DIR": str(root),
                           "FULL_PRODUCT_NAME": "Runner.app", "PROJECT_DIR": str(root)}
            with patch.object(embed, "ROOT", root), patch.object(embed.sys, "platform", "darwin"), \
                    patch.dict(embed.os.environ, environment), \
                    patch.object(embed.subprocess, "run", side_effect=RuntimeError("compiler reached")) as run:
                with self.assertRaisesRegex(RuntimeError, "compiler reached"):
                    embed.embed()
            command = run.call_args.args[0]
            for source in ("main.mm", "HostBrowserClient.mm", "NativeUi.mm"):
                self.assertIn(str(root / "Host" / source), command)
            output = root / "Runner.app/Contents/Frameworks/ChromiumWebViewHost.app/Contents/MacOS/ChromiumWebViewHost"
            self.assertEqual(command[command.index("-o") + 1], str(output))
            self.assertTrue(output.parent.is_dir())

    def test_debug_renderer_is_attachable_but_release_is_not(self):
        for configuration, expected in (("Debug", True), ("Release", False), ("Profile", False)):
            with self.subTest(configuration=configuration), patch.dict(embed.os.environ, {"CONFIGURATION": configuration}):
                values = embed.plistlib.loads(embed.renderer_entitlements().read_bytes())
                self.assertTrue(values["com.apple.security.cs.allow-jit"])
                self.assertEqual(bool(values.get("com.apple.security.get-task-allow")), expected)

    def test_cached_archive_must_match_checksum(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "archive"
            path.write_bytes(b"download")
            prepare.verify_archive(path, hashlib.sha256(b"download").hexdigest())
            path.write_bytes(b"tampered")
            with self.assertRaisesRegex(ValueError, "checksum mismatch"):
                prepare.verify_archive(path, hashlib.sha256(b"download").hexdigest())

    def test_archive_rejects_path_and_link_escapes(self):
        for name, linked in (("../escape", None), ("/absolute", None), ("root/link", "../../escape")):
            with self.subTest(name=name), tempfile.TemporaryDirectory() as directory:
                archive = Path(directory) / "archive.tar.bz2"
                target = Path(directory) / "target"
                target.mkdir()
                with tarfile.open(archive, "w:bz2") as output:
                    entry = tarfile.TarInfo(name)
                    if linked:
                        entry.type, entry.linkname = tarfile.SYMTYPE, linked
                        output.addfile(entry)
                    else:
                        entry.size = 1
                        output.addfile(entry, io.BytesIO(b"x"))
                with self.assertRaisesRegex(ValueError, "Unsafe archive"):
                    prepare.safe_extract(archive, target)
                self.assertFalse((Path(directory) / "escape").exists())

    def test_extraction_preserves_executable_mode(self):
        with tempfile.TemporaryDirectory() as directory:
            archive, target = Path(directory) / "archive.tar.bz2", Path(directory) / "target"
            target.mkdir()
            with tarfile.open(archive, "w:bz2") as output:
                entry = tarfile.TarInfo("root/helper")
                entry.size, entry.mode = 1, 0o755
                output.addfile(entry, io.BytesIO(b"x"))
            prepare.safe_extract(archive, target)
            self.assertEqual((target / "root/helper").read_bytes(), b"x")
            if prepare.platform.system() != "Windows":
                self.assertTrue((target / "root/helper").stat().st_mode & 0o111)

    def test_universal_build_fails_before_copying_framework(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / "cef").mkdir()
            (root / "cef/config.json").write_text('{"arch":"arm64"}')
            with patch.object(embed, "ROOT", root), patch.object(embed.sys, "platform", "darwin"), \
                    patch.dict(embed.os.environ, {"ARCHS": "arm64 x86_64"}):
                with self.assertRaisesRegex(RuntimeError, "exactly one architecture"):
                    embed.embed()

    def test_apple_app_sandbox_is_rejected_without_changing_entitlements(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / "cef").mkdir()
            (root / "cef/config.json").write_text('{"arch":"arm64"}')
            (root / "Runner.app/Contents").mkdir(parents=True)
            entitlements = root / "Runner.entitlements"
            original = embed.plistlib.dumps({"com.apple.security.app-sandbox": True})
            entitlements.write_bytes(original)
            environment = {"ARCHS": "arm64", "TARGET_BUILD_DIR": str(root),
                           "FULL_PRODUCT_NAME": "Runner.app", "PROJECT_DIR": str(root),
                           "CODE_SIGN_ENTITLEMENTS": "Runner.entitlements"}
            with patch.object(embed, "ROOT", root), patch.object(embed.sys, "platform", "darwin"), \
                    patch.dict(embed.os.environ, environment):
                with self.assertRaisesRegex(RuntimeError, "Apple's App Sandbox"):
                    embed.embed()
            self.assertEqual(entitlements.read_bytes(), original)


if __name__ == "__main__":
    unittest.main()
