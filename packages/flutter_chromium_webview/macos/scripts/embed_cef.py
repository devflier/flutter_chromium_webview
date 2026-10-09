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


def renderer_entitlements():
    name = "RendererDebug.entitlements" if os.environ.get("CONFIGURATION", "Release").lower() == "debug" else "Renderer.entitlements"
    return ROOT / "Helpers" / name


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
        
    project = Path(os.environ["PROJECT_DIR"])
    entitlements = os.environ.get("CODE_SIGN_ENTITLEMENTS")
    if entitlements:
        values = plistlib.loads((project / entitlements).read_bytes())
        if values.get("com.apple.security.app-sandbox"):
            raise RuntimeError("This CEF backend targets direct distribution, not Apple's App Sandbox; see MACOS.md")

    identity = os.environ.get("EXPANDED_CODE_SIGN_IDENTITY") or "-"

    sign_host_dest = None
    if app.name != "ChromiumWebViewHost.app":
        frameworks = contents / "Frameworks"
        frameworks.mkdir(exist_ok=True)
        
        host_dest = frameworks / "ChromiumWebViewHost.app"
        if host_dest.exists():
            shutil.rmtree(host_dest)
            
        (host_dest / "Contents/MacOS").mkdir(parents=True)
        (host_dest / "Contents/Frameworks").mkdir(parents=True)
        (host_dest / "Contents/Resources").mkdir(parents=True)
        
        with (host_dest / "Contents/Info.plist").open("wb") as output:
            plistlib.dump(helper_plist("ChromiumWebViewHost", "com.example.ChromiumWebViewHost"), output)
            
        sources = ROOT / "Host"
        command = ["xcrun", "clang++", "-std=c++20", "-arch", config["arch"],
                   "-fobjc-arc", "-mmacosx-version-min=13.0",
                   "-I" + str(ROOT / "cef/root"),
                   "-F" + str(ROOT / "cef/root/Release"),
                   "-L" + str(ROOT / "cef/build/lib")]
        if os.environ.get("CONFIGURATION", "Release").lower() == "debug":
            command += ["-DDEBUG=1", "-g"]
        else:
            command += ["-O2"]
        command += [str(sources / name) for name in (
            "main.mm", "ChromiumHostApp.mm", "IpcServer.mm", "IpcConnection.mm",
            "HostBrowserClient.mm", "JavaScriptRequests.mm")]
        command += [str(ROOT / "Classes/Protocol.mm"),
                    "-framework", "Chromium Embedded Framework", "-framework", "Cocoa",
                    "-framework", "IOSurface", "-framework", "CoreVideo", "-framework", "Metal",
                    "-lcef_dll_wrapper", "-o", str(host_dest / "Contents/MacOS/ChromiumWebViewHost")]
        subprocess.run(command, check=True)

        contents = host_dest / "Contents"
        sign_host_dest = host_dest

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
        entitlements = renderer_entitlements() if suffix == " (Renderer)" else None
        sign(frameworks / ("ChromiumWebView Helper" + suffix + ".app"), identity, entitlements)

    if sign_host_dest:
        sign(sign_host_dest, identity)
        print("Embedded ChromiumWebViewHost.app into Flutter App")

    print(f"Embedded CEF {config['version']} ({config['arch']}) and five signed helpers")


if __name__ == "__main__":
    embed()
