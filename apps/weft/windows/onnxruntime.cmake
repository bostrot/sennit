# ONNX Runtime for flutter_onnxruntime, fetched from NuGet.
#
# The Windows half of linux/onnxruntime.cmake, for the same reason: the plugin
# downloads its own copy from github.com/microsoft/onnxruntime/releases, every
# asset there now answers 404, and the plugin does not check its download — so
# the Windows build failed later with "ONNX Runtime extraction directory
# doesn't exist" and nothing about why.
#
# The same Microsoft.ML.OnnxRuntime package carries the win-x64 DLL, its
# import library and the headers. This fetches it once per machine, checks it
# against the pinned hash, and lays it out exactly where the plugin looks
# before it tries to download, which makes the plugin skip its download and
# bundle this copy.
#
# Included from CMakeLists.txt before the generated plugin rules. Keep both
# values in step with linux/onnxruntime.cmake: it is one package.

set(WEFT_ONNXRUNTIME_VERSION "1.22.0")
set(WEFT_ONNXRUNTIME_NUPKG_SHA256
    "d571e63a2329baacb713f441e65ad75284de354db6e1ac435fe4bebbb417986a")

# Keeps the plugin on the version this file provides rather than its own default.
set(ONNXRUNTIME_VERSION "${WEFT_ONNXRUNTIME_VERSION}" CACHE STRING
    "ONNX Runtime version to use" FORCE)

if(NOT CMAKE_SIZEOF_VOID_P EQUAL 8)
  message(FATAL_ERROR "No ONNX Runtime build for 32-bit Windows.")
endif()

# Outside the build directory, so a clean build does not fetch 120 MB again.
if(DEFINED ENV{LOCALAPPDATA} AND NOT "$ENV{LOCALAPPDATA}" STREQUAL "")
  file(TO_CMAKE_PATH "$ENV{LOCALAPPDATA}" _weft_cache_root)
else()
  set(_weft_cache_root "${CMAKE_BINARY_DIR}")
endif()
set(_weft_ort_cache
    "${_weft_cache_root}/sennit/onnxruntime/${WEFT_ONNXRUNTIME_VERSION}")
set(_weft_ort_unpacked "${_weft_ort_cache}/unpacked")
set(_weft_ort_native "${_weft_ort_unpacked}/runtimes/win-x64/native")

if(NOT EXISTS "${_weft_ort_unpacked}/build/native/include/onnxruntime_cxx_api.h"
   OR NOT EXISTS "${_weft_ort_native}/onnxruntime.dll")
  set(_weft_ort_nupkg "${_weft_ort_cache}/onnxruntime.nupkg")
  set(_weft_ort_url
      "https://api.nuget.org/v3-flatcontainer/microsoft.ml.onnxruntime/${WEFT_ONNXRUNTIME_VERSION}/microsoft.ml.onnxruntime.${WEFT_ONNXRUNTIME_VERSION}.nupkg")
  message(STATUS "Fetching ONNX Runtime ${WEFT_ONNXRUNTIME_VERSION} from NuGet")
  file(MAKE_DIRECTORY "${_weft_ort_cache}")
  file(DOWNLOAD "${_weft_ort_url}" "${_weft_ort_nupkg}"
       EXPECTED_HASH SHA256=${WEFT_ONNXRUNTIME_NUPKG_SHA256}
       STATUS _weft_ort_status
       TLS_VERIFY ON)
  list(GET _weft_ort_status 0 _weft_ort_code)
  if(NOT _weft_ort_code EQUAL 0)
    list(GET _weft_ort_status 1 _weft_ort_message)
    file(REMOVE "${_weft_ort_nupkg}")
    message(FATAL_ERROR
      "Could not download ONNX Runtime from ${_weft_ort_url}: ${_weft_ort_message}")
  endif()
  file(REMOVE_RECURSE "${_weft_ort_unpacked}")
  file(ARCHIVE_EXTRACT
       INPUT "${_weft_ort_nupkg}"
       DESTINATION "${_weft_ort_unpacked}"
       PATTERNS "build/native/include/*" "runtimes/win-x64/native/*")
  file(REMOVE "${_weft_ort_nupkg}")
endif()

# The layout the plugin's own download would have produced:
# <its binary dir>/onnxruntime/onnxruntime-win-x64-<version>/{include,lib}.
set(_weft_ort_target
    "${CMAKE_BINARY_DIR}/plugins/flutter_onnxruntime/onnxruntime/onnxruntime-win-x64-${WEFT_ONNXRUNTIME_VERSION}")
if(NOT EXISTS "${_weft_ort_target}/include/onnxruntime_cxx_api.h")
  file(REMOVE_RECURSE "${_weft_ort_target}")
  file(MAKE_DIRECTORY "${_weft_ort_target}/lib")
  file(COPY "${_weft_ort_unpacked}/build/native/include"
       DESTINATION "${_weft_ort_target}")
  file(COPY "${_weft_ort_native}/onnxruntime.dll"
            "${_weft_ort_native}/onnxruntime.lib"
            "${_weft_ort_native}/onnxruntime_providers_shared.dll"
            "${_weft_ort_native}/onnxruntime_providers_shared.lib"
       DESTINATION "${_weft_ort_target}/lib")
endif()
