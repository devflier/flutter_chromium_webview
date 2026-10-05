"""Launch a copied example bundle and require a normal, complete CEF shutdown."""
import argparse
from pathlib import Path
import plistlib
import shutil
import subprocess
import sys
import tempfile
import time


def smoke(source, logs):
    if sys.platform != "darwin":
        raise RuntimeError("macOS smoke validation requires a Mac")
    logs.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix="chromium-webview-smoke-") as directory:
        app = Path(directory) / source.name
        shutil.copytree(source, app, symlinks=True)
        info = plistlib.loads((app / "Contents/Info.plist").read_bytes())
        executable = app / "Contents/MacOS" / info["CFBundleExecutable"]
        stderr = logs / "macos-packaged-stderr.log"
        with stderr.open("wb") as output:
            process = subprocess.Popen([str(executable)], stdout=output, stderr=subprocess.STDOUT)
            try:
                deadline = time.monotonic() + 45
                while time.monotonic() < deadline:
                    if process.poll() is not None:
                        raise RuntimeError(f"App exited during startup: {process.returncode}")
                    if "[CEF] Initialization result: 1" in stderr.read_text(errors="replace"):
                        break
                    time.sleep(0.25)
                else:
                    raise RuntimeError("CEF startup timed out")
                # Address this exact test PID using NSRunningApplication's
                # ordinary Quit request, without AppleScript automation access.
                quit_tool = Path(directory) / "quit-test-app"
                subprocess.run(["xcrun", "clang++", "-fobjc-arc", "-framework", "AppKit",
                                str(Path(__file__).with_name("macos_quit.mm")), "-o", str(quit_tool)], check=True)
                subprocess.run([str(quit_tool), str(process.pid), str(app)], check=True, timeout=20)
                code = process.wait(timeout=20)
                if code != 0:
                    raise RuntimeError(f"Normal quit exited with code {code}")
                if "[CEF] Shutdown complete" not in stderr.read_text(errors="replace"):
                    raise RuntimeError("CEF shutdown did not complete")
                listing = subprocess.check_output(["ps", "-axo", "command="], text=True)
                if str(app / "Contents/Frameworks/ChromiumWebView Helper") in listing:
                    raise RuntimeError("CEF helpers survived application quit")
                print("Copied macOS bundle startup and normal shutdown passed")
            finally:
                if process.poll() is None:
                    process.terminate()
                    try:
                        process.wait(timeout=5)
                    except subprocess.TimeoutExpired:
                        process.kill()
                        process.wait()


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("app", type=Path)
    parser.add_argument("--logs", type=Path, default=Path(__file__).resolve().parents[1] / "docs/validation")
    args = parser.parse_args()
    smoke(args.app.resolve(), args.logs.resolve())
