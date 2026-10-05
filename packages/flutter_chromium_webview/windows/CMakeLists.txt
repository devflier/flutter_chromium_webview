# The Flutter tooling requires that developers have CMake 3.14 or later
# installed. You should not increase this version, as doing so will cause
# the plugin to fail to compile for some customers of the plugin.
cmake_minimum_required(VERSION 3.19)

# Project-level configuration.
set(PROJECT_NAME "flutter_chromium_webview")
project(${PROJECT_NAME} LANGUAGES CXX)

# CEF wrapper compilation can take a while, but MSVC uses multiple cores by default with /MP
set(CMAKE_CXX_STANDARD 20)
set(CMAKE_CXX_STANDARD_REQUIRED ON)

# Enforce dynamic runtime library (/MD) for all targets including CEF
if(POLICY CMP0091)
  cmake_policy(SET CMP0091 NEW)
endif()
set(CMAKE_MSVC_RUNTIME_LIBRARY "MultiThreaded$<$<CONFIG:Debug>:Debug>DLL")

# This value is used when generating builds using this plugin, so it must
# not be changed
set(PLUGIN_NAME "flutter_chromium_webview_plugin")

# Any new source files that you add to the plugin should be added here.
list(APPEND PLUGIN_SOURCES
  "flutter_chromium_webview_plugin_c_api.cpp"
  "flutter_chromium_webview_plugin.cpp"
  "cef_runtime_manager.cpp"
  "cef_browser_handler.cpp"
  "cef_texture.cpp"
  "cef_keyboard.cpp"
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
target_compile_definitions(${PLUGIN_NAME} PRIVATE FLUTTER_PLUGIN_IMPL NOMINMAX)

# Include custom CEF downloading and extraction
include(DownloadCEF.cmake)

# The CEF target is created by find_package(CEF) macro via libcef_dll_wrapper CMakeLists.
# Actually, the libcef_dll_wrapper target is created there. 
# libcef.lib is provided by CEF_LIBRARY_DIR

find_library(CEF_LIBRARY libcef HINTS "${CEF_LIBRARY_DIR}")

# Source include directories and library dependencies.
target_include_directories(${PLUGIN_NAME} INTERFACE
  "${CMAKE_CURRENT_SOURCE_DIR}/include")
target_include_directories(${PLUGIN_NAME} PRIVATE
  ${CEF_INCLUDE_DIR})

target_link_libraries(${PLUGIN_NAME} PRIVATE flutter flutter_wrapper_plugin)
target_link_libraries(${PLUGIN_NAME} PRIVATE ${CEF_WRAPPER_LIB} ${CEF_LIBRARY})
target_link_libraries(${PLUGIN_NAME} PRIVATE comctl32 imm32)

# CEF M138+ creates sandbox information in a prebuilt launcher, then loads the
# application's client DLL. The client exports RunWinMain and dispatches CEF.
set_property(TARGET ${PLUGIN_NAME} PROPERTY CHROMIUM_WEBVIEW_BOOTSTRAP
  "${CEF_LIBRARY_DIR}/bootstrap.exe")
function(chromium_webview_enable_sandbox runner_target)
  get_target_property(runner_type ${runner_target} TYPE)
  if(NOT runner_type STREQUAL "SHARED_LIBRARY")
    message(FATAL_ERROR "CEF sandbox runner must be a SHARED library exporting RunWinMain")
  endif()
  get_target_property(bootstrap flutter_chromium_webview_plugin CHROMIUM_WEBVIEW_BOOTSTRAP)
  add_custom_target(chromium_webview_bootstrap ALL
    COMMAND ${CMAKE_COMMAND} -E copy_if_different "${bootstrap}"
      "$<TARGET_FILE_DIR:${runner_target}>/$<TARGET_FILE_BASE_NAME:${runner_target}>.exe"
    DEPENDS ${runner_target}
    VERBATIM)
  install(PROGRAMS "${bootstrap}" DESTINATION "$<TARGET_FILE_DIR:${runner_target}>"
    RENAME "${runner_target}.exe" COMPONENT Runtime)
endfunction()

# Copy the subprocess executable and CEF dependencies to the output directory
# so they are bundled with the final application.
# List of absolute paths to libraries that should be bundled with the plugin.
set(flutter_chromium_webview_bundled_libraries
  "${CEF_LIBRARY_DIR}/libcef.dll"
  "${CEF_ROOT}/Resources/icudtl.dat"
  "${CEF_LIBRARY_DIR}/v8_context_snapshot.bin"
  "${CEF_LIBRARY_DIR}/vulkan-1.dll"
  "${CEF_LIBRARY_DIR}/vk_swiftshader.dll"
  "${CEF_LIBRARY_DIR}/vk_swiftshader_icd.json"
  "${CEF_LIBRARY_DIR}/libGLESv2.dll"
  "${CEF_LIBRARY_DIR}/libEGL.dll"
  "${CEF_LIBRARY_DIR}/chrome_elf.dll"
  "${CEF_LIBRARY_DIR}/d3dcompiler_47.dll"
  "${CEF_LIBRARY_DIR}/dxcompiler.dll"
  "${CEF_LIBRARY_DIR}/dxil.dll"
  "${CEF_ROOT}/LICENSE.txt"
)

# Copy the locales folder as well.
file(GLOB CEF_LOCALES "${CEF_ROOT}/Resources/locales/*.pak")
foreach(LOCALE_PAK ${CEF_LOCALES})
  list(APPEND flutter_chromium_webview_bundled_libraries "${LOCALE_PAK}")
endforeach()

file(GLOB CEF_RESOURCE_PAKS "${CEF_ROOT}/Resources/*.pak")
list(APPEND flutter_chromium_webview_bundled_libraries ${CEF_RESOURCE_PAKS})
set(flutter_chromium_webview_bundled_libraries
  ${flutter_chromium_webview_bundled_libraries} PARENT_SCOPE)

option(CHROMIUM_WEBVIEW_BUILD_TESTS "Build native texture regression tests" OFF)
if(CHROMIUM_WEBVIEW_BUILD_TESTS)
  enable_testing()
  add_executable(chromium_webview_texture_test "test/cef_texture_test.cpp" "cef_texture.cpp")
  apply_standard_settings(chromium_webview_texture_test)
  target_include_directories(chromium_webview_texture_test PRIVATE "${CMAKE_CURRENT_SOURCE_DIR}")
  target_link_libraries(chromium_webview_texture_test PRIVATE flutter_wrapper_plugin)
  add_test(NAME chromium_webview_texture_test COMMAND chromium_webview_texture_test)
endif()
