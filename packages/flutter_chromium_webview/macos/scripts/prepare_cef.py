"""Fetch the pinned CEF distribution and build its runtime loader and helper."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import platform
import subprocess
import tarfile
import tempfile
from urllib.parse import quote
from urllib.request import urlopen

VERSION = "149.0.4+g2f1bfd8+chromium-149.0.7827.156"
HASHES = {
    "arm64": "7eb30795aa583de17ce59ce38a420ef776a9f0412f9fe0e90306bf3dc94b0b62",
    "x86_64": "75639ff6181a63194b1aae1c69ad1aa7fc2033dcc92b11554c57844c86f4e4bb",
}
ROOT = Path(__file__).resolve().parent.parent


def verify_archive(path, expected):
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(chunk)
    if digest.hexdigest() != expected:
        raise ValueError(f"CEF archive checksum mismatch: {path}")


def safe_extract(archive, destination):
    # Validate members and link targets on Python versions without tar's data filter.
    base = destination.resolve()
    with tarfile.open(archive, "r:bz2") as stream:
        members = stream.getmembers()
        for member in members:
            target = (base / member.name).resolve()
            if base != target and base not in target.parents:
                raise ValueError(f"Unsafe archive path: {member.name}")
            if member.isdev() or member.isfifo():
                raise ValueError(f"Unsupported archive entry: {member.name}")
            if member.issym() or member.islnk():
                linked = ((target.parent if member.issym() else base) / member.linkname).resolve()
                if base != linked and base not in linked.parents:
                    raise ValueError(f"Unsafe archive link: {member.name}")
        if hasattr(tarfile, "data_filter"):
            stream.extractall(base, members=members, filter="data")
        else:
            stream.extractall(base, members=members)


def prepare(arch):
    if platform.system() != "Darwin":
        raise RuntimeError("CEF macOS preparation requires a Mac with Xcode and CMake")
    cache = ROOT / "cef"
    cache.mkdir(exist_ok=True)
    config_path = cache / "config.json"
    if config_path.exists() and json.loads(config_path.read_text())["arch"] != arch:
        raise RuntimeError("CEF cache belongs to another architecture; use a separate checkout/build")
    platform_name = "macosarm64" if arch == "arm64" else "macosx64"
    distribution = f"cef_binary_{VERSION}_{platform_name}_minimal"
    archive = cache / f"{distribution}.tar.bz2"
    if not archive.exists():
        print(f"Downloading CEF {VERSION} ({arch})", flush=True)
        temporary = archive.with_suffix(".download")
        with urlopen("https://cef-builds.spotifycdn.com/" + quote(archive.name), timeout=120) as source:
            with temporary.open("wb") as output:
                while True:
                    chunk = source.read(1024 * 1024)
                    if not chunk:
                        break
                    output.write(chunk)
        verify_archive(temporary, HASHES[arch])
        temporary.replace(archive)
    verify_archive(archive, HASHES[arch])
    cef_root = cache / "root"
    if not cef_root.exists():
        with tempfile.TemporaryDirectory(dir=cache) as temporary:
            staging = Path(temporary)
            safe_extract(archive, staging)
            (staging / distribution).rename(cef_root)
    build = cache / "build"
    subprocess.run(["cmake", "-S", str(ROOT), "-B", str(build), "-G", "Unix Makefiles",
                    f"-DCEF_ROOT={cef_root}", f"-DCMAKE_OSX_ARCHITECTURES={arch}",
                    "-DCMAKE_BUILD_TYPE=Release", "-DPROJECT_ARCH=" + ("arm64" if arch == "arm64" else "x86_64")], check=True)
    subprocess.run(["cmake", "--build", str(build), "--parallel", "2"], check=True)
    config_path.write_text(json.dumps({"arch": arch, "version": VERSION}) + "\n")
    print(f"CEF prepared for {arch}", flush=True)


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--arch", choices=HASHES, default=os.environ.get("CHROMIUM_WEBVIEW_MACOS_ARCH", platform.machine()))
    args = parser.parse_args()
    if args.arch not in HASHES:
        parser.error("Supported macOS architectures: arm64 or x86_64")
    prepare(args.arch)
