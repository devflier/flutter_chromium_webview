# Contributing to Flutter Chromium WebView

We welcome contributions from the community! This document outlines how to set up your development environment, run tests, and submit changes to `flutter_chromium_webview`.

## Getting Started: Where to Begin

If you are a new contributor, the best place to start is the `packages/flutter_chromium_webview` directory. 
- The Dart API lives in `lib/flutter_chromium_webview.dart`.
- The native C++ implementation lives in `linux/`.
- The example application in `example/` is the primary testbed for new features.

Before contributing, please read the [Architecture Documentation](docs/architecture.md) to understand how the plugin interacts with CEF and Flutter.

## Prerequisites

### Supported Versions
* **Flutter**: 3.47.0 or newer.
* **Dart**: 3.13.3 or newer.

### Linux Native Dependencies
Building the native Linux implementation requires the following tools and libraries:
* Clang
* CMake
* Ninja (`ninja-build`)
* pkg-config
* GTK3 development files (`libgtk-3-dev`)

On Ubuntu/Debian, you can install these with:
```bash
sudo apt-get install clang cmake ninja-build pkg-config libgtk-3-dev
```

### CEF Distribution and Build Configuration
CEF (Chromium Embedded Framework) is a large dependency. You do not need to download it manually; the custom CMake scripts located in `packages/flutter_chromium_webview/linux/` will automatically download the correct CEF binary distribution and configure it during your first build. 

*Note: CEF packaging can take several minutes on the first run, especially if you are building on a mounted drive (like `/mnt/c` in WSL).*

## Development Workflow

### Cloning and Building

1. Clone the repository:
   ```bash
   git clone <repository-url>
   cd flutter_chromium_webview
   ```

2. Run `flutter pub get` in the main package and the example:
   ```bash
   cd packages/flutter_chromium_webview
   flutter pub get
   cd example
   flutter pub get
   ```

### Running the Example

The example application demonstrates all supported features and serves as an interactive testing ground.

To run the example natively on Linux:
```bash
cd packages/flutter_chromium_webview/example
flutter run -d linux
```

### Testing under WSLg

If you are developing on Windows, you can use WSL2 with WSLg to run the Linux desktop application. Because WSLg's hardware acceleration can be inconsistent across host GPUs, we recommend forcing software rendering.

Use the provided script from the repository root:
```bash
bash scripts/run_wsl.sh
```

For more details on WSLg testing, see [docs/wslg.md](docs/wslg.md).

## Running Tests

### Dart Tests
The Dart unit tests and method channel tests can be run from the package directory:
```bash
cd packages/flutter_chromium_webview
flutter test
```

### Native Tests
Native tests are opt-in through `CHROMIUM_WEBVIEW_BUILD_TESTS=ON`. Linux uses
installed GoogleTest (`libgtest-dev` and `libgmock-dev`); Windows has a standalone
frame ownership regression executable. The Windows validation script builds and
runs it. Enable the option in the example's CMake build, build the native test
target, then run CTest in the plugin build directory.

Run `scripts/validate_linux.sh` on Linux, or
`powershell -File scripts/validate_windows.ps1` on Windows. See
[Windows runner setup](docs/windows.md) for the required bootstrap integration.
Run desktop integration suites as separate Flutter invocations: the current
Flutter desktop log reader closes after its first process exits.

### Integration Tests
To run the full native lifecycle and input regression tests, use the following commands from the `example` directory. (If running under WSLg, use the environment variables shown):

```bash
cd packages/flutter_chromium_webview/example

# Run lifecycle tests
LIBGL_ALWAYS_SOFTWARE=1 GALLIUM_DRIVER=llvmpipe GDK_BACKEND=x11 \
  flutter test integration_test/plugin_integration_test.dart -d linux

# Run input and resize scaling tests
LIBGL_ALWAYS_SOFTWARE=1 GALLIUM_DRIVER=llvmpipe GDK_BACKEND=x11 \
  flutter test integration_test/input_scaling_test.dart -d linux
```

## Reporting Bugs

For the initial macOS backend, follow
[MACOS.md](packages/flutter_chromium_webview/MACOS.md) and run
`bash scripts/validate_macos.sh` on a Mac with Xcode, CocoaPods, Python and CMake.
Package tests on Windows/Linux do not verify macOS native compilation or runtime.

To report a bug, please open an issue on the issue tracker. Include:
1. A clear description of the problem.
2. Steps to reproduce.
3. Your Flutter version (`flutter doctor -v`).
4. Whether you are running on native Linux or WSLg.
5. Relevant crash logs or console output.

## Submitting Changes

1. Fork the repository and create a new branch.
2. Ensure your code follows the existing style. Run `dart format` on all Dart files.
3. Run `flutter analyze` to check for linter warnings.
4. Ensure all existing tests pass (`flutter test`).
5. If adding a new feature, update the example application to demonstrate it and add relevant tests.
6. Submit a Pull Request.

Please keep pull requests focused on a single feature or bug fix.
