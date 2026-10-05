Pod::Spec.new do |s|
  s.name = 'flutter_chromium_webview'
  s.version = '0.1.0'
  s.summary = 'Experimental CEF texture backend for Flutter macOS.'
  s.description = 'Chromium off-screen rendering with sandboxed helper apps. See MACOS.md for required Runner setup.'
  s.homepage = 'https://chromiumembedded.github.io/cef/'
  s.license = { :type => 'MIT', :file => '../LICENSE' }
  s.author = { 'Flutter Chromium WebView contributors' => '' }
  s.source = { :path => '.' }
  s.source_files = 'Classes/**/*.{h,mm}'
  s.public_header_files = 'Classes/FlutterChromiumWebviewPlugin.h'
  s.dependency 'FlutterMacOS'
  s.platform = :osx, '13.0'
  s.requires_arc = true
  s.frameworks = 'Cocoa', 'CoreVideo', 'IOSurface', 'Metal'
  s.libraries = 'c++'
  s.preserve_paths = 'cef/**/*', 'scripts/**/*', 'Helpers/**/*', 'CMakeLists.txt', '../native/**/*'
  s.vendored_libraries = 'cef/build/lib/libcef_dll_wrapper.a'
  # CocoaPods skips prepare_command for development/path pods. See Podfile setup
  # in MACOS.md; the example prepares explicitly before pod installation.
  s.prepare_command = 'python3 scripts/prepare_cef.py'
  s.pod_target_xcconfig = {
    'DEFINES_MODULE' => 'YES',
    'CLANG_CXX_LANGUAGE_STANDARD' => 'c++20',
    'HEADER_SEARCH_PATHS' => '$(inherited) "${PODS_TARGET_SRCROOT}/cef/root"',
    'GCC_PREPROCESSOR_DEFINITIONS' => '$(inherited) CEF_USE_SANDBOX',
    'OTHER_LDFLAGS' => '$(inherited) -ObjC',
  }
end
