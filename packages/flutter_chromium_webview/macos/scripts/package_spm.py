import os
import subprocess
import shutil
from pathlib import Path
import hashlib

def generate_checksum(file_path):
    hash_sha256 = hashlib.sha256()
    with open(file_path, "rb") as f:
        for chunk in iter(lambda: f.read(4096), b""):
            hash_sha256.update(chunk)
    return hash_sha256.hexdigest()

def main():
    root_dir = Path(__file__).resolve().parent.parent
    cef_dir = root_dir / "cef"
    
    print("1. Running prepare_cef.py to ensure CEF is downloaded and wrapper is built...")
    subprocess.run(["python3", str(root_dir / "scripts" / "prepare_cef.py")], check=True)
    
    cef_framework_path = cef_dir / "root" / "Release" / "Chromium Embedded Framework.framework"
    cef_wrapper_lib = cef_dir / "build" / "lib" / "libcef_dll_wrapper.a"
    
    # We only want the include headers, not the entire CEF root (which has Release/ binaries)
    cef_headers = cef_dir / "temp_headers"
    if cef_headers.exists():
        shutil.rmtree(cef_headers)
    os.makedirs(cef_headers, exist_ok=True)
    # xcodebuild -headers includes the contents of the folder.
    # To maintain the "include/cef_app.h" structure, we need to copy include into temp_headers/include
    shutil.copytree(cef_dir / "root" / "include", cef_headers / "include")
    
    cef_xcframework = cef_dir / "CEF.xcframework"
    wrapper_xcframework = cef_dir / "CEFWrapper.xcframework"
    
    print("2. Creating XCFrameworks...")
    if cef_xcframework.exists():
        shutil.rmtree(cef_xcframework)
    subprocess.run([
        "xcodebuild", "-create-xcframework",
        "-framework", str(cef_framework_path),
        "-output", str(cef_xcframework)
    ], check=True)
    
    if wrapper_xcframework.exists():
        shutil.rmtree(wrapper_xcframework)
    subprocess.run([
        "xcodebuild", "-create-xcframework",
        "-library", str(cef_wrapper_lib),
        "-headers", str(cef_headers),
        "-output", str(wrapper_xcframework)
    ], check=True)
    
    print("3. Zipping XCFrameworks for SPM distribution...")
    cef_zip = cef_dir / "CEF.xcframework.zip"
    wrapper_zip = cef_dir / "CEFWrapper.xcframework.zip"
    
    subprocess.run(["zip", "-r", "-y", "-q", "CEF.xcframework.zip", "CEF.xcframework"], cwd=cef_dir, check=True)
    subprocess.run(["zip", "-r", "-y", "-q", "CEFWrapper.xcframework.zip", "CEFWrapper.xcframework"], cwd=cef_dir, check=True)
    
    print("\n=== SPM PREPARATION COMPLETE ===")
    print(f"CEF.xcframework.zip checksum: {generate_checksum(cef_zip)}")
    print(f"CEFWrapper.xcframework.zip checksum: {generate_checksum(wrapper_zip)}")
    print("\nNext steps for SPM support:")
    print("1. Upload these two .zip files to a GitHub Release (e.g. v0.5.0)")
    print("2. Update Package.swift with the URLs and these checksums.")

if __name__ == "__main__":
    main()
