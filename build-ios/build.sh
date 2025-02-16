#!/bin/bash

set -e

# Config

export SCONS="scons -j${NUM_CORES} verbose=yes warnings=no progress=no"
# Keep LTO disabled for iOS - it works but it makes linking apps on deploy very slow,
# which is seen as a regression in the current workflow.
export OPTIONS="production=yes use_lto=no"
export OPTIONS_MONO="module_mono_enabled=yes"
export TERM=xterm

export IOS_SDK="18.2"
export IOS_LIPO="/root/ioscross/arm64/bin/arm-apple-darwin11-lipo"

build_x86_64=1
build_arm64=1

_build_star=0

if [ ! -z "${BUILD_TARGETS}" ]; then
  # Reset all targets, since we're explicitly specifying which ones to build.
  build_x86_64=0
  build_arm64=0

  IFS=';' read -ra targets_array <<< "${BUILD_TARGETS}"
  for target in "${targets_array[@]}"; do
    if [[ "$target" == ios ]]; then
      # This is the equivalent of 'ios_*'.
      _build_star=1
    elif [[ "$target" == ios_x86_64 ]]; then
      build_x86_64=1
    elif [[ "$target" == ios_arm64 ]]; then
      build_arm64=1
    fi
  done
fi

if [ "${_build_star}" == 1 ]; then
  build_x86_64=1
  build_arm64=1
fi

rm -rf godot
mkdir godot
cd godot
tar xf /root/godot.tar.gz --strip-components=1

# Classical

if [ "${CLASSICAL}" == "1" ]; then
  echo "Starting classical build for iOS..."

  if [ "${BUILD_EXPORT_TEMPLATES}" == "1" ]; then
    if [ "${build_arm64}" == 1 ]; then
      # arm64 device
      $SCONS platform=ios $OPTIONS arch=arm64 ios_simulator=no target=template_debug \
        IOS_SDK_PATH="/root/ioscross/arm64/SDK/iPhoneOS${IOS_SDK}.sdk" IOS_TOOLCHAIN_PATH="/root/ioscross/arm64/" ios_triple="arm-apple-darwin11-"
      $SCONS platform=ios $OPTIONS arch=arm64 ios_simulator=no target=template_release \
        IOS_SDK_PATH="/root/ioscross/arm64/SDK/iPhoneOS${IOS_SDK}.sdk" IOS_TOOLCHAIN_PATH="/root/ioscross/arm64/" ios_triple="arm-apple-darwin11-"

      # arm64 simulator
      # Disabled for now as it doesn't work with cctools-port and current LLVM.
      # See https://github.com/godotengine/build-containers/pull/85.
      #$SCONS platform=ios $OPTIONS arch=arm64 ios_simulator=yes target=template_debug \
      #  IOS_SDK_PATH="/root/ioscross/arm64_sim/SDK/iPhoneSimulator${IOS_SDK}.sdk" IOS_TOOLCHAIN_PATH="/root/ioscross/arm64_sim/" ios_triple="arm-apple-darwin11-"
      #$SCONS platform=ios $OPTIONS arch=arm64 ios_simulator=yes target=template_release \
      #  IOS_SDK_PATH="/root/ioscross/arm64_sim/SDK/iPhoneSimulator${IOS_SDK}.sdk" IOS_TOOLCHAIN_PATH="/root/ioscross/arm64_sim/" ios_triple="arm-apple-darwin11-"
    fi

    if [ "${build_x86_64}" == 1 ]; then
      # x86_64 simulator
      $SCONS platform=ios $OPTIONS arch=x86_64 ios_simulator=yes target=template_debug \
        IOS_SDK_PATH="/root/ioscross/x86_64_sim/SDK/iPhoneSimulator${IOS_SDK}.sdk" IOS_TOOLCHAIN_PATH="/root/ioscross/x86_64_sim/" ios_triple="x86_64-apple-darwin11-"
      $SCONS platform=ios $OPTIONS arch=x86_64 ios_simulator=yes target=template_release \
        IOS_SDK_PATH="/root/ioscross/x86_64_sim/SDK/iPhoneSimulator${IOS_SDK}.sdk" IOS_TOOLCHAIN_PATH="/root/ioscross/x86_64_sim/" ios_triple="x86_64-apple-darwin11-"
    fi

    mkdir -p /root/out/templates
    if [ "${build_arm64}" == 1 ]; then
      cp bin/libgodot.ios.template_release.arm64.a /root/out/templates/libgodot.ios.a
      cp bin/libgodot.ios.template_debug.arm64.a /root/out/templates/libgodot.ios.debug.a
      #$IOS_LIPO -create bin/libgodot.ios.template_release.arm64.simulator.a bin/libgodot.ios.template_release.x86_64.simulator.a -output /root/out/templates/libgodot.ios.simulator.a
      #$IOS_LIPO -create bin/libgodot.ios.template_debug.arm64.simulator.a bin/libgodot.ios.template_debug.x86_64.simulator.a -output /root/out/templates/libgodot.ios.debug.simulator.a
    fi
    if [ "${build_x86_64}" == 1 ]; then
      cp bin/libgodot.ios.template_release.x86_64.simulator.a /root/out/templates/libgodot.ios.simulator.a
      cp bin/libgodot.ios.template_debug.x86_64.simulator.a /root/out/templates/libgodot.ios.debug.simulator.a
    fi
  fi
fi

# Mono

if [ "${MONO}" == "1" ]; then
  echo "Starting Mono build for iOS..."

  if [ "${BUILD_EXPORT_TEMPLATES}" == "1" ]; then
    cp -r /root/mono-glue/GodotSharp/GodotSharp/Generated modules/mono/glue/GodotSharp/GodotSharp/

    if [ "${build_arm64}" == 1 ]; then
      # arm64 device
      $SCONS platform=ios $OPTIONS $OPTIONS_MONO arch=arm64 ios_simulator=no target=template_debug \
        IOS_SDK_PATH="/root/ioscross/arm64/SDK/iPhoneOS${IOS_SDK}.sdk" IOS_TOOLCHAIN_PATH="/root/ioscross/arm64/" ios_triple="arm-apple-darwin11-"
      $SCONS platform=ios $OPTIONS $OPTIONS_MONO arch=arm64 ios_simulator=no target=template_release \
        IOS_SDK_PATH="/root/ioscross/arm64/SDK/iPhoneOS${IOS_SDK}.sdk" IOS_TOOLCHAIN_PATH="/root/ioscross/arm64/" ios_triple="arm-apple-darwin11-"

      # arm64 simulator
      # Disabled for now as it doesn't work with cctools-port and current LLVM.
      # See https://github.com/godotengine/build-containers/pull/85.
      #$SCONS platform=ios $OPTIONS $OPTIONS_MONO arch=arm64 ios_simulator=yes target=template_debug \
      #  IOS_SDK_PATH="/root/ioscross/arm64_sim/SDK/iPhoneSimulator${IOS_SDK}.sdk" IOS_TOOLCHAIN_PATH="/root/ioscross/arm64_sim/" ios_triple="arm-apple-darwin11-"
      #$SCONS platform=ios $OPTIONS $OPTIONS_MONO arch=arm64 ios_simulator=yes target=template_release \
      #  IOS_SDK_PATH="/root/ioscross/arm64_sim/SDK/iPhoneSimulator${IOS_SDK}.sdk" IOS_TOOLCHAIN_PATH="/root/ioscross/arm64_sim/" ios_triple="arm-apple-darwin11-"
    fi

    if [ "${build_x86_64}" == 1 ]; then
      # x86_64 simulator
      $SCONS platform=ios $OPTIONS $OPTIONS_MONO arch=x86_64 ios_simulator=yes target=template_debug \
        IOS_SDK_PATH="/root/ioscross/x86_64_sim/SDK/iPhoneSimulator${IOS_SDK}.sdk" IOS_TOOLCHAIN_PATH="/root/ioscross/x86_64_sim/" ios_triple="x86_64-apple-darwin11-"
      $SCONS platform=ios $OPTIONS $OPTIONS_MONO arch=x86_64 ios_simulator=yes target=template_release \
        IOS_SDK_PATH="/root/ioscross/x86_64_sim/SDK/iPhoneSimulator${IOS_SDK}.sdk" IOS_TOOLCHAIN_PATH="/root/ioscross/x86_64_sim/" ios_triple="x86_64-apple-darwin11-"
    fi

      mkdir -p /root/out/templates-mono

    if [ "${build_arm64}" == 1 ]; then
      cp bin/libgodot.ios.template_release.arm64.a /root/out/templates-mono/libgodot.ios.a
      cp bin/libgodot.ios.template_debug.arm64.a /root/out/templates-mono/libgodot.ios.debug.a
      #$IOS_LIPO -create bin/libgodot.ios.template_release.arm64.simulator.a bin/libgodot.ios.template_release.x86_64.simulator.a -output /root/out/templates-mono/libgodot.ios.simulator.a
      #$IOS_LIPO -create bin/libgodot.ios.template_debug.arm64.simulator.a bin/libgodot.ios.template_debug.x86_64.simulator.a -output /root/out/templates-mono/libgodot.ios.debug.simulator.a
    fi
    if [ "${build_x86_64}" == 1 ]; then
      cp bin/libgodot.ios.template_release.x86_64.simulator.a /root/out/templates-mono/libgodot.ios.simulator.a
      cp bin/libgodot.ios.template_debug.x86_64.simulator.a /root/out/templates-mono/libgodot.ios.debug.simulator.a
    fi
  fi
fi

echo "iOS build successful"
