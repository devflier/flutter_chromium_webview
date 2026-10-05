# Download and extract CEF
set(CEF_VERSION "149.0.4+g2f1bfd8+chromium-149.0.7827.156")
set(CEF_DISTRIBUTION "cef_binary_${CEF_VERSION}_linux64_minimal")
set(CEF_DOWNLOAD_URL "https://cef-builds.spotifycdn.com/${CEF_DISTRIBUTION}.tar.bz2")
set(CEF_DOWNLOAD_DIR "${CMAKE_CURRENT_BINARY_DIR}/cef_download")
set(CEF_TARBALL "${CEF_DOWNLOAD_DIR}/${CEF_DISTRIBUTION}.tar.bz2" CACHE FILEPATH "Pinned CEF archive, optionally pre-downloaded")
set(CEF_SHA256 "6d43607675e47ed6bfa40d1cfce136d04e7720529f8f1c4435d4ba1dcd1839b2")
set(CEF_EXTRACT_DIR "${CMAKE_CURRENT_BINARY_DIR}/cef")
set(CEF_ROOT "${CEF_EXTRACT_DIR}/${CEF_DISTRIBUTION}")

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
endif()

set(CEF_INCLUDE_DIR "${CEF_ROOT}")
set(CEF_LIBRARY_DIR "${CEF_ROOT}/Release")

# Include CEF CMake macros required for libcef_dll_wrapper
# CEF's cmake files require find_package(CEF)
set(CMAKE_MODULE_PATH ${CMAKE_MODULE_PATH} "${CEF_ROOT}/cmake")
if(POLICY CMP0074)
  cmake_policy(SET CMP0074 NEW)
endif()
find_package(CEF REQUIRED)

# We will need the libcef.so and libcef_dll_wrapper.
# The minimal distribution contains libcef.so but not the compiled wrapper.
# We have to build libcef_dll_wrapper.
add_subdirectory("${CEF_ROOT}/libcef_dll" "${CMAKE_CURRENT_BINARY_DIR}/libcef_dll")
set(CEF_WRAPPER_LIB libcef_dll_wrapper)
