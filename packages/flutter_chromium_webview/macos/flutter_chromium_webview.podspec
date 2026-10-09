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
  s.preserve_paths = 'cef/**/*', 'scripts/**/*', 'Helpers/**/*', 'Host/**/*', 'CMakeLists.txt', '../native/**/*'
  # CocoaPods skips prepare_command for development/path pods.
  # Using script_phases allows downloading and building during the Xcode build,
  # and removing vendored_libraries prevents pod install from failing if the library is missing.
  s.script_phase = {
    :name => 'Prepare CEF Framework',
    :script => 'python3 "${PODS_TARGET_SRCROOT}/scripts/prepare_cef.py" --arch ${ARCHS%% *}',
    :execution_position => :before_compile,
  }
  s.pod_target_xcconfig = {
    'DEFINES_MODULE' => 'YES',
    'CLANG_CXX_LANGUAGE_STANDARD' => 'c++20',
    'HEADER_SEARCH_PATHS' => '$(inherited) "${PODS_TARGET_SRCROOT}/cef/root"',
    'GCC_PREPROCESSOR_DEFINITIONS' => '$(inherited) CEF_USE_SANDBOX',
    'OTHER_LDFLAGS' => '$(inherited) -ObjC -framework "FlutterMacOS" -F"${PODS_TARGET_SRCROOT}/cef/root/Release" -L"${PODS_TARGET_SRCROOT}/cef/build/lib" -lcef_dll_wrapper',
  }
end
