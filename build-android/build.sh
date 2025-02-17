#!/bin/bash

set -e

# Config

export SCONS="scons -j${NUM_CORES} verbose=yes warnings=no progress=no"
export OPTIONS="production=yes"
export OPTIONS_MONO="module_mono_enabled=yes"
export OPTIONS_DOTNET="module_dotnet_enabled=yes"
export TERM=xterm

build_x86_64=1
build_x86_32=1
build_arm64=1
build_arm32=1

_build_star=0

if [ ! -z "${BUILD_TARGETS}" ]; then
  # Reset all targets, since we're explicitly specifying which ones to build.
  build_x86_64=0
  build_x86_32=0
  build_arm64=0
  build_arm32=0

  IFS=';' read -ra targets_array <<< "${BUILD_TARGETS}"
  for target in "${targets_array[@]}"; do
    if [[ "$target" == android ]]; then
      # This is the equivalent of 'android_*'.
      _build_star=1
    elif [[ "$target" == android_x86_64 ]]; then
      build_x86_64=1
    elif [[ "$target" == android_x86_32 ]]; then
      build_x86_32=1
    elif [[ "$target" == android_arm64 ]]; then
      build_arm64=1
    elif [[ "$target" == android_arm32 ]]; then
      build_arm32=1
    fi
  done
fi

if [ "${_build_star}" == 1 ]; then
  build_x86_64=1
  build_x86_32=1
  build_arm64=1
  build_arm32=1
fi

rm -rf godot
mkdir godot
cd godot
tar xf /root/godot.tar.gz --strip-components=1
cp -rf /root/swappy/* thirdparty/swappy-frame-pacing/

# Environment variables and keystore needed for signing store editor build,
# as well as signing and publishing to MavenCentral.
source /root/keystore/config.sh

store_release="yes"
if [ -z "${GODOT_ANDROID_SIGN_KEYSTORE}" ]; then
  echo "No keystore provided to sign the Android release editor build, using debug build instead."
  store_release="no"
fi

# Classical

if [ "${CLASSICAL}" == "1" ]; then
  echo "Starting classical build for Android..."

  $SCONS platform=android arch=arm32 $OPTIONS target=editor store_release=${store_release}
  $SCONS platform=android arch=arm64 $OPTIONS target=editor store_release=${store_release}
  $SCONS platform=android arch=x86_32 $OPTIONS target=editor store_release=${store_release}
  $SCONS platform=android arch=x86_64 $OPTIONS target=editor store_release=${store_release}

  pushd platform/android/java
  # Generate the regular Android editor.
  ./gradlew generateGodotEditor
  # Generate the Android editor for HorizonOS devices.
  ./gradlew generateGodotHorizonOSEditor
  # Generate the Android editor for PicoOS devices.
  ./gradlew generateGodotPicoOSEditor
  popd

  mkdir -p /root/out/tools
  # Copy the generated Android editor binaries (apk & aab).
  if [ "$store_release" == "yes" ]; then
    cp bin/android_editor_builds/android_editor-android-release.apk /root/out/tools/android_editor.apk
    cp bin/android_editor_builds/android_editor-android-release.aab /root/out/tools/android_editor.aab
    # For the HorizonOS and PicoOS builds, we only copy the apk.
    cp bin/android_editor_builds/android_editor-horizonos-release.apk /root/out/tools/android_editor_horizonos.apk
    cp bin/android_editor_builds/android_editor-picoos-release.apk /root/out/tools/android_editor_picoos.apk
  else
    cp bin/android_editor_builds/android_editor-android-debug.apk /root/out/tools/android_editor.apk
    cp bin/android_editor_builds/android_editor-android-debug.aab /root/out/tools/android_editor.aab
    # For the HorizonOS and PicoOS build, we only copy the apk.
    cp bin/android_editor_builds/android_editor-horizonos-debug.apk /root/out/tools/android_editor_horizonos.apk
    cp bin/android_editor_builds/android_editor-picoos-debug.apk /root/out/tools/android_editor_picoos.apk
  fi

  if [ "${BUILD_EXPORT_TEMPLATES}" == "1" ]; then
    # Restart from a clean tarball, as we'll copy all the contents
    # outside the container for the MavenCentral upload.
    rm -rf /root/godot/*
    tar xf /root/godot.tar.gz --strip-components=1
    cp -rf /root/swappy/* thirdparty/swappy-frame-pacing/

    if [ "${build_arm32}" == 1 ]; then
      $SCONS platform=android arch=arm32 $OPTIONS target=template_debug
      $SCONS platform=android arch=arm32 $OPTIONS target=template_release
    fi

    if [ "${build_arm64}" == 1 ]; then
      $SCONS platform=android arch=arm64 $OPTIONS target=template_debug
      $SCONS platform=android arch=arm64 $OPTIONS target=template_release
    fi

    if [ "${build_x86_32}" == 1 ]; then
      $SCONS platform=android arch=x86_32 $OPTIONS target=template_debug
      $SCONS platform=android arch=x86_32 $OPTIONS target=template_release
    fi

    if [ "${build_x86_64}" == 1 ]; then
      $SCONS platform=android arch=x86_64 $OPTIONS target=template_debug
      $SCONS platform=android arch=x86_64 $OPTIONS target=template_release
    fi

    pushd platform/android/java
    ./gradlew generateGodotTemplates

    if [ "$store_release" == "yes" ]; then
      # Copy source folder with compiled libs so we can optionally use it
      # in a separate script to upload the templates to MavenCentral.
      cp -r /root/godot /root/out/source/
      # Backup ~/.gradle too so we can reuse all the downloaded stuff.
      cp -r /root/.gradle /root/out/source/.gradle
    fi
    popd

    mkdir -p /root/out/templates
    cp bin/android_source.zip /root/out/templates/
    cp bin/android_debug.apk /root/out/templates/
    cp bin/android_release.apk /root/out/templates/
    cp bin/godot-lib.template_release.aar /root/out/templates/
  fi
fi

# Mono

if [ "${MONO}" == "1" ]; then
  echo "Starting Mono build for Android..."

  if [ "${BUILD_EXPORT_TEMPLATES}" == "1" ]; then
    cp -r /root/mono-glue/GodotSharp/GodotSharp/Generated modules/mono/glue/GodotSharp/GodotSharp/


    if [ "${build_arm32}" == 1 ]; then
        $SCONS platform=android arch=arm32 $OPTIONS $OPTIONS_MONO target=template_debug
        $SCONS platform=android arch=arm32 $OPTIONS $OPTIONS_MONO target=template_release
    fi

    if [ "${build_arm64}" == 1 ]; then
      $SCONS platform=android arch=arm64 $OPTIONS $OPTIONS_MONO target=template_debug
      $SCONS platform=android arch=arm64 $OPTIONS $OPTIONS_MONO target=template_release
    fi

    if [ "${build_x86_32}" == 1 ]; then
      $SCONS platform=android arch=x86_32 $OPTIONS $OPTIONS_MONO target=template_debug
      $SCONS platform=android arch=x86_32 $OPTIONS $OPTIONS_MONO target=template_release
    fi

    if [ "${build_x86_64}" == 1 ]; then
      $SCONS platform=android arch=x86_64 $OPTIONS $OPTIONS_MONO target=template_debug
      $SCONS platform=android arch=x86_64 $OPTIONS $OPTIONS_MONO target=template_release
    fi

    pushd platform/android/java
    ./gradlew generateGodotMonoTemplates
    popd

    mkdir -p /root/out/templates-mono
    cp bin/android_source.zip /root/out/templates-mono/
    cp bin/android_monoDebug.apk /root/out/templates-mono/android_debug.apk
    cp bin/android_monoRelease.apk /root/out/templates-mono/android_release.apk
    cp bin/godot-lib.template_release.aar /root/out/templates-mono/
  fi
fi

# .NET

if [ "${DOTNET}" == "1" ]; then
  echo "Starting .NET build for Android..."

  if [ "${BUILD_EXPORT_TEMPLATES}" == "1" ]; then
    if [ "${build_arm32}" == 1 ]; then
        $SCONS platform=android arch=arm32 $OPTIONS $OPTIONS_DOTNET target=template_debug
        $SCONS platform=android arch=arm32 $OPTIONS $OPTIONS_DOTNET target=template_release
    fi

    if [ "${build_arm64}" == 1 ]; then
      $SCONS platform=android arch=arm64 $OPTIONS $OPTIONS_DOTNET target=template_debug
      $SCONS platform=android arch=arm64 $OPTIONS $OPTIONS_DOTNET target=template_release
    fi

    if [ "${build_x86_32}" == 1 ]; then
      $SCONS platform=android arch=x86_32 $OPTIONS $OPTIONS_DOTNET target=template_debug
      $SCONS platform=android arch=x86_32 $OPTIONS $OPTIONS_DOTNET target=template_release
    fi

    if [ "${build_x86_64}" == 1 ]; then
      $SCONS platform=android arch=x86_64 $OPTIONS $OPTIONS_DOTNET target=template_debug
      $SCONS platform=android arch=x86_64 $OPTIONS $OPTIONS_DOTNET target=template_release
    fi

    pushd platform/android/java
    ./gradlew generateGodotMonoTemplates
    popd

    mkdir -p /root/out/templates-dotnet
    cp bin/android_source.zip /root/out/templates-dotnet/
    cp bin/android_dotnetDebug.apk /root/out/templates-dotnet/android_debug.apk
    cp bin/android_dotnetRelease.apk /root/out/templates-dotnet/android_release.apk
    cp bin/godot-lib.template_release.aar /root/out/templates-dotnet/
  fi
fi

echo "Android build successful"
