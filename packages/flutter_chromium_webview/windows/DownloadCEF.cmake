# Download and extract CEF
set(CEF_VERSION "149.0.4+g2f1bfd8+chromium-149.0.7827.156")
set(CEF_DISTRIBUTION "cef_binary_${CEF_VERSION}_windows64_minimal")
set(CEF_DOWNLOAD_URL "https://cef-builds.spotifycdn.com/${CEF_DISTRIBUTION}.tar.bz2")
set(CEF_DOWNLOAD_DIR "${CMAKE_CURRENT_BINARY_DIR}/cef_download")
set(CEF_TARBALL "${CEF_DOWNLOAD_DIR}/${CEF_DISTRIBUTION}.tar.bz2" CACHE FILEPATH "Pinned CEF archive, optionally pre-downloaded")
set(CEF_SHA256 "17b7b9f9f8e33c571631e3fb3ed84a48a0ea9d7e54f9f7d40d207f019c6a02d5")
set(CEF_EXTRACT_DIR "${CMAKE_CURRENT_BINARY_DIR}/cef")
set(CEF_ROOT "${CEF_EXTRACT_DIR}/root")

if(NOT EXISTS "${CEF_ROOT}")
    message(STATUS "Downloading CEF ${CEF_VERSION}...")
    file(MAKE_DIRECTORY "${CEF_DOWNLOAD_DIR}")
    
    # We use URL encoding for the `+` character
    string(REPLACE "+" "%2B" ENCODED_URL "${CEF_DOWNLOAD_URL}")
    
    if(NOT EXISTS "${CEF_TARBALL}")
      file(DOWNLOAD "${ENCODED_URL}" "${CEF_TARBALL}"
         EXPECTED_HASH SHA256=${CEF_SHA256}
         SHOW_PROGRESS
         STATUS DOWNLOAD_STATUS)
    
    list(GET DOWNLOAD_STATUS 0 STATUS_CODE)
    if(NOT STATUS_CODE EQUAL 0)
        message(FATAL_ERROR "Failed to download CEF: ${DOWNLOAD_STATUS}")
    endif()
    endif()
    file(SHA256 "${CEF_TARBALL}" ACTUAL_CEF_SHA256)
    if(NOT ACTUAL_CEF_SHA256 STREQUAL CEF_SHA256)
      message(FATAL_ERROR "CEF archive checksum mismatch: ${CEF_TARBALL}")
    endif()

    message(STATUS "Extracting CEF...")
    file(MAKE_DIRECTORY "${CEF_EXTRACT_DIR}")
    execute_process(
        COMMAND ${CMAKE_COMMAND} -E tar xf "${CEF_TARBALL}"
        WORKING_DIRECTORY "${CEF_EXTRACT_DIR}"
        RESULT_VARIABLE EXTRACT_RESULT
    )
    if(NOT EXTRACT_RESULT EQUAL 0)
        message(FATAL_ERROR "Failed to extract CEF tarball.")
    endif()
    file(RENAME "${CEF_EXTRACT_DIR}/${CEF_DISTRIBUTION}" "${CEF_EXTRACT_DIR}/root")
    
    # Patch CEF variables to ensure it uses /MD instead of /MT
    set(CEF_VARS_FILE "${CEF_EXTRACT_DIR}/root/cmake/cef_variables.cmake")
    if(EXISTS "${CEF_VARS_FILE}")
        file(READ "${CEF_VARS_FILE}" CEF_VARS_CONTENT)
        string(REPLACE "/MT" "/MD" CEF_VARS_CONTENT "${CEF_VARS_CONTENT}")
        file(WRITE "${CEF_VARS_FILE}" "${CEF_VARS_CONTENT}")
    endif()
endif()

set(CEF_ROOT "${CEF_EXTRACT_DIR}/root")

set(CEF_INCLUDE_DIR "${CEF_ROOT}")
set(CEF_LIBRARY_DIR "${CEF_ROOT}/Release")

# Include CEF CMake macros required for libcef_dll_wrapper
# CEF's cmake files require find_package(CEF)
set(CMAKE_MODULE_PATH ${CMAKE_MODULE_PATH} "${CEF_ROOT}/cmake")
if(POLICY CMP0074)
  cmake_policy(SET CMP0074 NEW)
endif()
# CEF's wrapper uses /MD; sandbox support comes from bootstrap.exe, not the
# legacy cef_sandbox static-library CMake path.
set(USE_SANDBOX OFF CACHE BOOL "Use sandbox" FORCE)
set(CEF_RUNTIME_LIBRARY_FLAG "/MD" CACHE STRING "" FORCE)
set(CEF_COMPILER_FLAGS "/MD")

find_package(CEF REQUIRED)

# Replace any /MT or /MTd defaults with /MD or /MDd
foreach(flag_var
        CMAKE_C_FLAGS CMAKE_C_FLAGS_DEBUG CMAKE_C_FLAGS_RELEASE
        CMAKE_C_FLAGS_MINSIZEREL CMAKE_C_FLAGS_RELWITHDEBINFO
        CMAKE_CXX_FLAGS CMAKE_CXX_FLAGS_DEBUG CMAKE_CXX_FLAGS_RELEASE
        CMAKE_CXX_FLAGS_MINSIZEREL CMAKE_CXX_FLAGS_RELWITHDEBINFO)
  if(${flag_var} MATCHES "/MT")
    string(REGEX REPLACE "/MT" "/MD" ${flag_var} "${${flag_var}}")
  endif()
endforeach()

# We will need the libcef.dll and libcef_dll_wrapper.
# The minimal distribution contains libcef.dll but not the compiled wrapper.
# We have to build libcef_dll_wrapper.
# In windows, MSVC will be used.
add_subdirectory("${CEF_ROOT}/libcef_dll" "${CMAKE_CURRENT_BINARY_DIR}/libcef_dll")
set(CEF_WRAPPER_LIB libcef_dll_wrapper)
