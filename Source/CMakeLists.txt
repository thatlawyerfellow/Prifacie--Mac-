cmake_minimum_required(VERSION 3.16)
project(PriFacieBrowser LANGUAGES CXX OBJCXX)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_CXX_EXTENSIONS OFF)
set(CMAKE_OBJCXX_STANDARD 17)
set(CMAKE_OBJCXX_STANDARD_REQUIRED ON)

if(NOT APPLE)
  message(FATAL_ERROR "This build is macOS-only. Use Apple Clang on macOS.")
endif()

set(OPENSSL_USE_STATIC_LIBS TRUE)
find_package(OpenSSL REQUIRED)

set(APP_ICON_ICO "${CMAKE_SOURCE_DIR}/favicon.ico")
set(APP_ICON_ICNS "")

find_program(SIPS_EXECUTABLE sips)
find_program(ICONUTIL_EXECUTABLE iconutil)

if(EXISTS "${APP_ICON_ICO}" AND SIPS_EXECUTABLE AND ICONUTIL_EXECUTABLE)
  set(APP_ICONSET_DIR "${CMAKE_BINARY_DIR}/PriFacie.iconset")
  set(APP_ICON_BASE_PNG "${CMAKE_BINARY_DIR}/PriFacie-base.png")
  set(APP_ICON_ICNS "${CMAKE_BINARY_DIR}/PriFacie.icns")

  add_custom_command(
    OUTPUT "${APP_ICON_ICNS}"
    COMMAND "${CMAKE_COMMAND}" -E rm -rf "${APP_ICONSET_DIR}"
    COMMAND "${CMAKE_COMMAND}" -E make_directory "${APP_ICONSET_DIR}"
    COMMAND "${SIPS_EXECUTABLE}" -s format png "${APP_ICON_ICO}" --out "${APP_ICON_BASE_PNG}"
    COMMAND "${SIPS_EXECUTABLE}" -z 16 16 "${APP_ICON_BASE_PNG}" --out "${APP_ICONSET_DIR}/icon_16x16.png"
    COMMAND "${SIPS_EXECUTABLE}" -z 32 32 "${APP_ICON_BASE_PNG}" --out "${APP_ICONSET_DIR}/icon_16x16@2x.png"
    COMMAND "${SIPS_EXECUTABLE}" -z 32 32 "${APP_ICON_BASE_PNG}" --out "${APP_ICONSET_DIR}/icon_32x32.png"
    COMMAND "${SIPS_EXECUTABLE}" -z 64 64 "${APP_ICON_BASE_PNG}" --out "${APP_ICONSET_DIR}/icon_32x32@2x.png"
    COMMAND "${SIPS_EXECUTABLE}" -z 128 128 "${APP_ICON_BASE_PNG}" --out "${APP_ICONSET_DIR}/icon_128x128.png"
    COMMAND "${SIPS_EXECUTABLE}" -z 256 256 "${APP_ICON_BASE_PNG}" --out "${APP_ICONSET_DIR}/icon_128x128@2x.png"
    COMMAND "${SIPS_EXECUTABLE}" -z 256 256 "${APP_ICON_BASE_PNG}" --out "${APP_ICONSET_DIR}/icon_256x256.png"
    COMMAND "${SIPS_EXECUTABLE}" -z 512 512 "${APP_ICON_BASE_PNG}" --out "${APP_ICONSET_DIR}/icon_256x256@2x.png"
    COMMAND "${SIPS_EXECUTABLE}" -z 512 512 "${APP_ICON_BASE_PNG}" --out "${APP_ICONSET_DIR}/icon_512x512.png"
    COMMAND "${SIPS_EXECUTABLE}" -z 1024 1024 "${APP_ICON_BASE_PNG}" --out "${APP_ICONSET_DIR}/icon_512x512@2x.png"
    COMMAND "${ICONUTIL_EXECUTABLE}" -c icns "${APP_ICONSET_DIR}" -o "${APP_ICON_ICNS}"
    DEPENDS "${APP_ICON_ICO}"
    VERBATIM
  )
endif()

add_executable(prifacie-browser MACOSX_BUNDLE
  src/main.mm
  src/browser_window_mac.mm
  src/engine_adapter_mac.mm
  src/profile_store.cpp
  src/crypto_utils.cpp
  src/credential_store.cpp
  src/browser_data_store.cpp
)

target_include_directories(prifacie-browser PRIVATE src)

target_compile_options(prifacie-browser PRIVATE
  -Wall
  -Wextra
  -Wpedantic
  $<$<CONFIG:Release>:-O3>
  $<$<CONFIG:Release>:-fstack-protector-strong>
  $<$<CONFIG:Release>:-D_FORTIFY_SOURCE=2>
)

target_link_options(prifacie-browser PRIVATE
  $<$<CONFIG:Release>:-Wl,-dead_strip>
)

target_link_libraries(prifacie-browser PRIVATE
  OpenSSL::Crypto
  "-framework Cocoa"
  "-framework Security"
  "-framework WebKit"
  "-framework Foundation"
  "-framework UniformTypeIdentifiers"
)

set_target_properties(prifacie-browser PROPERTIES
  OUTPUT_NAME "PriFacie"
  MACOSX_BUNDLE_BUNDLE_NAME "PriFacie"
  MACOSX_BUNDLE_GUI_IDENTIFIER "com.ajaykumar.prifacie"
  MACOSX_BUNDLE_SHORT_VERSION_STRING "0.1"
  MACOSX_BUNDLE_BUNDLE_VERSION "0.1"
  MACOSX_BUNDLE_COPYRIGHT "(c) Ajay Kumar 2026 All Rights Reserved"
)

if(APP_ICON_ICNS)
  set_source_files_properties("${APP_ICON_ICNS}" PROPERTIES
    MACOSX_PACKAGE_LOCATION "Resources"
  )
  target_sources(prifacie-browser PRIVATE "${APP_ICON_ICNS}")
  set_target_properties(prifacie-browser PROPERTIES
    MACOSX_BUNDLE_ICON_FILE "PriFacie.icns"
  )
endif()

if(EXISTS "${APP_ICON_ICO}")
  set_source_files_properties("${APP_ICON_ICO}" PROPERTIES
    MACOSX_PACKAGE_LOCATION "Resources"
  )
  target_sources(prifacie-browser PRIVATE "${APP_ICON_ICO}")
endif()

set_source_files_properties(src/main.mm src/browser_window_mac.mm src/engine_adapter_mac.mm PROPERTIES
  COMPILE_FLAGS "-fobjc-arc"
)

install(TARGETS prifacie-browser
  BUNDLE DESTINATION .
  RUNTIME DESTINATION bin
)
