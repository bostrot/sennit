# ONNX Runtime for flutter_onnxruntime, fetched from NuGet.
#
# The plugin downloads its own copy of ONNX Runtime from
# github.com/microsoft/onnxruntime/releases. That repository stopped resolving
# — every release asset now answers 404 — and the plugin does not check its
# download, so a Linux build failed later with "ONNX Runtime extraction
# directory doesn't exist" and nothing about why. Every Linux build broke at
# once: CI's route walk and integration jobs, the Linux release, and any local
# `flutter run -d linux`.
#
# Microsoft also publishes the same build to NuGet as Microsoft.ML.OnnxRuntime,
# with the Linux libraries (same SONAME, libonnxruntime.so.1) and the C/C++
# headers inside. This fetches that package once per machine, checks it against
# a pinned hash, and lays it out exactly where the plugin looks before it tries
# to download — which makes the plugin skip its download and bundle this copy.
#
# Included from CMakeLists.txt before the generated plugin rules. When the
# plugin moves to a new ONNX Runtime version, change both values below.

set(WEFT_ONNXRUNTIME_VERSION "1.22.0")
set(WEFT_ONNXRUNTIME_NUPKG_SHA256
    "d571e63a2329baacb713f441e65ad75284de354db6e1ac435fe4bebbb417986a")

# Keeps the plugin on the version this file provides rather than its own default.
set(ONNXRUNTIME_VERSION "${WEFT_ONNXRUNTIME_VERSION}" CACHE STRING
    "ONNX Runtime version to use" FORCE)

if(CMAKE_SYSTEM_PROCESSOR MATCHES "aarch64|arm64")
  set(_weft_ort_arch "aarch64")
  set(_weft_ort_rid "linux-arm64")
elseif(CMAKE_SYSTEM_PROCESSOR MATCHES "x86_64|AMD64")
  set(_weft_ort_arch "x64")
  set(_weft_ort_rid "linux-x64")
else()
  message(FATAL_ERROR
    "No ONNX Runtime build for processor '${CMAKE_SYSTEM_PROCESSOR}'.")
endif()

# Outside the build directory, so a clean build — and CI's checkout, which
# deletes `build/` — does not fetch 120 MB again.
if(DEFINED ENV{XDG_CACHE_HOME} AND NOT "$ENV{XDG_CACHE_HOME}" STREQUAL "")
  set(_weft_cache_root "$ENV{XDG_CACHE_HOME}")
else()
  set(_weft_cache_root "$ENV{HOME}/.cache")
endif()
set(_weft_ort_cache
    "${_weft_cache_root}/sennit/onnxruntime/${WEFT_ONNXRUNTIME_VERSION}")
set(_weft_ort_unpacked "${_weft_ort_cache}/unpacked")

if(NOT EXISTS "${_weft_ort_unpacked}/build/native/include/onnxruntime_cxx_api.h"
   OR NOT EXISTS "${_weft_ort_unpacked}/runtimes/${_weft_ort_rid}/native/libonnxruntime.so")
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
       PATTERNS "build/native/include/*" "runtimes/linux-*/native/*")
  file(REMOVE "${_weft_ort_nupkg}")
endif()

# The layout the plugin's own download would have produced:
# <its binary dir>/onnxruntime/onnxruntime-linux-<arch>-<version>/{include,lib}.
set(_weft_ort_target
    "${CMAKE_BINARY_DIR}/plugins/flutter_onnxruntime/onnxruntime/onnxruntime-linux-${_weft_ort_arch}-${WEFT_ONNXRUNTIME_VERSION}")
if(NOT EXISTS "${_weft_ort_target}/include/onnxruntime_cxx_api.h")
  file(REMOVE_RECURSE "${_weft_ort_target}")
  file(MAKE_DIRECTORY "${_weft_ort_target}/lib")
  file(COPY "${_weft_ort_unpacked}/build/native/include"
       DESTINATION "${_weft_ort_target}")
  set(_weft_ort_lib "libonnxruntime.so.${WEFT_ONNXRUNTIME_VERSION}")
  file(COPY_FILE
       "${_weft_ort_unpacked}/runtimes/${_weft_ort_rid}/native/libonnxruntime.so"
       "${_weft_ort_target}/lib/${_weft_ort_lib}")
  file(COPY_FILE
       "${_weft_ort_unpacked}/runtimes/${_weft_ort_rid}/native/libonnxruntime_providers_shared.so"
       "${_weft_ort_target}/lib/libonnxruntime_providers_shared.so")
  # SONAME is libonnxruntime.so.1; the plugin links and bundles
  # lib/libonnxruntime.so. Same chain as the GitHub release archive.
  file(CREATE_LINK "${_weft_ort_lib}"
       "${_weft_ort_target}/lib/libonnxruntime.so.1" SYMBOLIC)
  file(CREATE_LINK "libonnxruntime.so.1"
       "${_weft_ort_target}/lib/libonnxruntime.so" SYMBOLIC)
endif()
