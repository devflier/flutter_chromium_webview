"""Runner build phase: bundle the CEF framework and sandboxed helper apps."""
import json
import os
from pathlib import Path
import plistlib
import shutil
import subprocess
import sys

ROOT = Path(__file__).resolve().parent.parent
SUFFIXES = ("", " (Alerts)", " (GPU)", " (Plugin)", " (Renderer)")


def helper_plist(name, identifier):
    return {"CFBundleExecutable": name, "CFBundleName": name,
            "CFBundleIdentifier": identifier, "CFBundlePackageType": "APPL",
            "CFBundleVersion": "1", "CFBundleShortVersionString": "1.0",
            "LSUIElement": True, "LSMinimumSystemVersion": "13.0",
            "NSPrincipalClass": "NSApplication"}


def sign(path, identity, entitlements=None):
    command = ["codesign", "--force", "--sign", identity]
    if identity != "-":
        command += ["--options", "runtime", "--timestamp"]
    if entitlements:
        command += ["--entitlements", str(entitlements)]
    subprocess.run(command + [str(path)], check=True)


def embed():
    if sys.platform != "darwin":
        raise RuntimeError("CEF embedding requires macOS")
    config = json.loads((ROOT / "cef/config.json").read_text())
    archs = os.environ.get("ARCHS", "").split()
    if archs != [config["arch"]]:
        raise RuntimeError(f"Build exactly one architecture ({config['arch']}); universal CEF bundles are not implemented")
    app = Path(os.environ["TARGET_BUILD_DIR"]) / os.environ["FULL_PRODUCT_NAME"]
    contents = app / "Contents"
    if app.suffix != ".app" or not contents.is_dir():
        raise RuntimeError(f"Expected built Runner app: {app}")
        
    identity = os.environ.get("EXPANDED_CODE_SIGN_IDENTITY") or "-"

    if app.name != "ChromiumWebViewHost.app":
        frameworks = contents / "Frameworks"
        frameworks.mkdir(exist_ok=True)
        host_source = ROOT / "Host" / "ChromiumWebViewHost.app"
        if host_source.exists():
            host_dest = frameworks / "ChromiumWebViewHost.app"
            if host_dest.exists():
                shutil.rmtree(host_dest)
            shutil.copytree(host_source, host_dest, symlinks=True)
            
            # Re-sign the inner frameworks and helpers with the current identity
            host_frameworks = host_dest / "Contents" / "Frameworks"
            cef_framework = host_frameworks / "Chromium Embedded Framework.framework"
            if cef_framework.exists():
                for library in sorted((cef_framework / "Versions/A/Libraries").glob("*.dylib")):
                    sign(library, identity)
                sign(cef_framework, identity)
                
            for suffix in SUFFIXES:
                helper_app = host_frameworks / ("ChromiumWebView Helper" + suffix + ".app")
                if helper_app.exists():
                    entitlements = ROOT / "Helpers/Renderer.entitlements" if suffix == " (Renderer)" else None
                    sign(helper_app, identity, entitlements)
            
            sign(host_dest, identity)
        print("Embedded ChromiumWebViewHost.app into Flutter App")
        return

    project = Path(os.environ["PROJECT_DIR"])
    entitlements = os.environ.get("CODE_SIGN_ENTITLEMENTS")
    if entitlements:
        values = plistlib.loads((project / entitlements).read_bytes())
        if values.get("com.apple.security.app-sandbox"):
            raise RuntimeError("This CEF backend targets direct distribution, not Apple's App Sandbox; see MACOS.md")
    framework_source = ROOT / "cef/root/Release/Chromium Embedded Framework.framework"
    frameworks = contents / "Frameworks"
    frameworks.mkdir(exist_ok=True)
    # The CEF archive is flat; its loader/sandbox require a standard versioned
    # framework and symlinks, as in CEF's COPY_MAC_FRAMEWORK macro.
    framework = frameworks / framework_source.name
    version = framework / "Versions/A"
    shutil.copytree(framework_source, version, symlinks=True, dirs_exist_ok=True)
    for name in ("Chromium Embedded Framework", "Libraries", "Resources"):
        link = framework / name
        if not link.exists() and not link.is_symlink():
            link.symlink_to(f"Versions/A/{name}")
    current = framework / "Versions/Current"
    if not current.exists():
        current.symlink_to("A")
    identifier = os.environ["PRODUCT_BUNDLE_IDENTIFIER"]
    for suffix in SUFFIXES:
        name = "ChromiumWebView Helper" + suffix
        helper = frameworks / (name + ".app") / "Contents"
        (helper / "MacOS").mkdir(parents=True, exist_ok=True)
        shutil.copy2(ROOT / "cef/build/bin/chromium_webview_helper", helper / "MacOS" / name)
        tag = suffix.strip(" ()").lower()
        with (helper / "Info.plist").open("wb") as output:
            plistlib.dump(helper_plist(name, identifier + ".cef-helper" + ("." + tag if tag else "")), output)
    shutil.copy2(ROOT / "cef/root/LICENSE.txt", contents / "Resources/CEF-LICENSE.txt")
    # Sign nested code from the inside out. Never use --deep to generate a signature.
    for library in sorted((version / "Libraries").glob("*.dylib")):
        sign(library, identity)
    sign(framework, identity)
    for suffix in SUFFIXES:
        entitlements = ROOT / "Helpers/Renderer.entitlements" if suffix == " (Renderer)" else None
        sign(frameworks / ("ChromiumWebView Helper" + suffix + ".app"), identity, entitlements)

    print(f"Embedded CEF {config['version']} ({config['arch']}) and five signed helpers")


if __name__ == "__main__":
    embed()
