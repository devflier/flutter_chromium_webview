# The Flutter tooling requires that developers have CMake 3.10 or later
# installed. You should not increase this version, as doing so will cause
# the plugin to fail to compile for some customers of the plugin.
cmake_minimum_required(VERSION 3.19)

# Project-level configuration.
set(PROJECT_NAME "flutter_chromium_webview")
project(${PROJECT_NAME} LANGUAGES C CXX)

set(CMAKE_CXX_STANDARD 20)
set(CMAKE_CXX_STANDARD_REQUIRED ON)

# CEF wrapper compilation can exhaust small WSL VMs when Ninja uses every CPU.
set(CHROMIUM_WEBVIEW_COMPILE_JOBS 2 CACHE STRING "Maximum concurrent CEF/plugin compiler jobs")
set_property(GLOBAL APPEND PROPERTY JOB_POOLS chromium_compile=${CHROMIUM_WEBVIEW_COMPILE_JOBS})
set(CMAKE_JOB_POOL_COMPILE chromium_compile)

# This value is used when generating builds using this plugin, so it must
# not be changed.
set(PLUGIN_NAME "flutter_chromium_webview_plugin")

# Any new source files that you add to the plugin should be added here.
list(APPEND PLUGIN_SOURCES
  "flutter_chromium_webview_plugin.cc"
  "cef_runtime_manager.cc"
  "cef_browser_handler.cc"
  "cef_texture.cc"
  "cef_keyboard.cc"
)

# Define the plugin library target. Its name must not be changed (see comment
# on PLUGIN_NAME above).
add_library(${PLUGIN_NAME} SHARED
  ${PLUGIN_SOURCES}
)

# Apply a standard set of build settings that are configured in the
# application-level CMakeLists.txt. This can be removed for plugins that want
# full control over build settings.
apply_standard_settings(${PLUGIN_NAME})

# Symbols are hidden by default to reduce the chance of accidental conflicts
# between plugins. This should not be removed; any symbols that should be
# exported should be explicitly exported with the FLUTTER_PLUGIN_EXPORT macro.
set_target_properties(${PLUGIN_NAME} PROPERTIES
  CXX_VISIBILITY_PRESET hidden)
target_compile_definitions(${PLUGIN_NAME} PRIVATE FLUTTER_PLUGIN_IMPL)

# Include custom CEF downloading and extraction
include(DownloadCEF.cmake)

add_library(chromium_cef SHARED IMPORTED GLOBAL)
set_target_properties(chromium_cef PROPERTIES
  IMPORTED_LOCATION "${CEF_LIBRARY_DIR}/libcef.so"
  IMPORTED_NO_SONAME TRUE)

# Chromium's libc interceptors use RTLD_NEXT, so CEF must precede libc in
# the executable's dependency list, even though Flutter loads it via a plugin.
if(TARGET ${BINARY_NAME})
  # Keep the linker group together so CMake cannot deduplicate/reorder -lcef.
  set_property(TARGET ${BINARY_NAME} APPEND_STRING PROPERTY LINK_FLAGS
    " -L\"${CEF_LIBRARY_DIR}\" -Wl,--no-as-needed,-lcef,--as-needed")
endif()

# Source include directories and library dependencies. Add any plugin-specific
# dependencies here.
target_include_directories(${PLUGIN_NAME} INTERFACE
  "${CMAKE_CURRENT_SOURCE_DIR}/include")
target_include_directories(${PLUGIN_NAME} PRIVATE
  ${CEF_INCLUDE_DIR})

target_link_libraries(${PLUGIN_NAME} PRIVATE flutter)
target_link_libraries(${PLUGIN_NAME} PRIVATE PkgConfig::GTK)
target_link_libraries(${PLUGIN_NAME} PRIVATE ${CEF_WRAPPER_LIB})
# We must link to libcef.so as well
target_link_libraries(${PLUGIN_NAME} PRIVATE chromium_cef)

# Compile the CEF subprocess executable
add_executable(flutter_chromium_webview_subprocess
  "subprocess/cef_subprocess.cc"
)
target_include_directories(flutter_chromium_webview_subprocess PRIVATE
  ${CEF_INCLUDE_DIR})
target_link_libraries(flutter_chromium_webview_subprocess PRIVATE
  ${CEF_WRAPPER_LIB}
  chromium_cef)

# Configure RPATH for subprocess so it finds libcef.so
set_target_properties(flutter_chromium_webview_subprocess PROPERTIES
  INSTALL_RPATH "$ORIGIN"
  BUILD_WITH_INSTALL_RPATH TRUE
)

# Flutter's install(FILES) strips executable permission on native Linux. Install
# the subprocess after the consuming application's bundle cleanup/copy rules.
function(_chromium_install_subprocess)
  install(PROGRAMS "$<TARGET_FILE:flutter_chromium_webview_subprocess>"
    DESTINATION lib COMPONENT Runtime)
endfunction()
cmake_language(DEFER DIRECTORY "${CMAKE_SOURCE_DIR}" CALL _chromium_install_subprocess)

# List of absolute paths to libraries that should be bundled with the plugin.
# This list could contain prebuilt libraries, or libraries created by an
# external build triggered from this build file.
set(flutter_chromium_webview_bundled_libraries
  "${CEF_LIBRARY_DIR}/libcef.so"
  "${CEF_ROOT}/Resources/icudtl.dat"
  "${CEF_LIBRARY_DIR}/v8_context_snapshot.bin"
  "${CEF_LIBRARY_DIR}/libvulkan.so.1"
  "${CEF_LIBRARY_DIR}/libvk_swiftshader.so"
  "${CEF_LIBRARY_DIR}/libGLESv2.so"
  "${CEF_LIBRARY_DIR}/libEGL.so"
  "${CEF_ROOT}/LICENSE.txt"
)

# Copy the locales folder as well. Since bundled_libraries only takes files,
# we can't easily add a whole directory to it without listing every file.
# However, CEF allows us to configure where to look for locales and resources.
# We will set CefSettings.resources_dir_path and locales_dir_path to the 'lib' dir
# and copy the locales there.
file(GLOB CEF_LOCALES "${CEF_ROOT}/Resources/locales/*.pak")
foreach(LOCALE_PAK ${CEF_LOCALES})
  list(APPEND flutter_chromium_webview_bundled_libraries "${LOCALE_PAK}")
endforeach()

file(GLOB CEF_RESOURCE_PAKS "${CEF_ROOT}/Resources/*.pak")
list(APPEND flutter_chromium_webview_bundled_libraries ${CEF_RESOURCE_PAKS})
set(flutter_chromium_webview_bundled_libraries
  ${flutter_chromium_webview_bundled_libraries} PARENT_SCOPE)


# === Tests ===
# Only fetch gtest if tests are actually being built.
option(CHROMIUM_WEBVIEW_BUILD_TESTS "Build native plugin tests using installed GoogleTest" OFF)
if(CHROMIUM_WEBVIEW_BUILD_TESTS)
  enable_testing()
  find_package(GTest CONFIG REQUIRED)

  add_executable(${PLUGIN_NAME}_test
    "test/flutter_chromium_webview_plugin_test.cc"
    ${PLUGIN_SOURCES}
  )
  target_include_directories(${PLUGIN_NAME}_test PRIVATE "${CMAKE_CURRENT_SOURCE_DIR}" "${CMAKE_CURRENT_SOURCE_DIR}/include")
  target_include_directories(${PLUGIN_NAME}_test PRIVATE ${CEF_INCLUDE_DIR})
  target_compile_definitions(${PLUGIN_NAME}_test PRIVATE FLUTTER_PLUGIN_IMPL)

  target_link_libraries(${PLUGIN_NAME}_test PRIVATE flutter)
  target_link_libraries(${PLUGIN_NAME}_test PRIVATE PkgConfig::GTK)
  target_link_libraries(${PLUGIN_NAME}_test PRIVATE ${CEF_WRAPPER_LIB})
  target_link_libraries(${PLUGIN_NAME}_test PRIVATE chromium_cef)
  target_link_libraries(${PLUGIN_NAME}_test PRIVATE GTest::gtest_main GTest::gmock)
  set_property(TARGET ${PLUGIN_NAME}_test APPEND_STRING PROPERTY LINK_FLAGS
    " -L\"${CEF_LIBRARY_DIR}\" -Wl,--no-as-needed,-lcef,--as-needed")

  add_test(NAME ${PLUGIN_NAME}_test COMMAND ${PLUGIN_NAME}_test)
endif()
