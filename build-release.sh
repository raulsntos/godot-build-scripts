#!/bin/bash

set -e
export basedir=$(pwd)

# Config

# For signing keystore and password.
source ./config.sh

can_sign_windows=0
if [ ! -z "${SIGN_KEYSTORE}" ] && [ ! -z "${SIGN_PASSWORD}" ] && [[ $(type -P "osslsigncode") ]]; then
  can_sign_windows=1
else
  echo "Disabling Windows binary signing as config.sh does not define the required data (SIGN_KEYSTORE, SIGN_PASSWORD), or osslsigncode can't be found in PATH."
fi

sign_windows() {
  if [ $can_sign_windows == 0 ]; then
    return
  fi
  osslsigncode sign -pkcs12 ${SIGN_KEYSTORE} -pass "${SIGN_PASSWORD}" -n "${SIGN_NAME}" -i "${SIGN_URL}" -t http://timestamp.comodoca.com -in $1 -out $1-signed
  mv $1-signed $1
}

sign_macos() {
  if [ -z "${OSX_HOST}" ]; then
    return
  fi
  _macos_tmpdir=$(ssh "${OSX_HOST}" "mktemp -d")
  _reldir="$1"
  _binname="$2"
  _is_mono="$3"

  if [[ "${_is_mono}" == "1" ]]; then
    _appname="Godot_mono.app"
    _sharpdir="${_appname}/Contents/Resources/GodotSharp"
  else
    _appname="Godot.app"
  fi

  scp "${_reldir}/${_binname}.zip" "${OSX_HOST}:${_macos_tmpdir}"
  scp "${basedir}/git/misc/dist/macos/editor.entitlements" "${OSX_HOST}:${_macos_tmpdir}"
  ssh "${OSX_HOST}" "
            cd ${_macos_tmpdir} && \
            unzip ${_binname}.zip && \
            codesign --force --timestamp \
              --options=runtime --entitlements editor.entitlements \
              -s ${OSX_KEY_ID} -v ${_appname} && \
            zip -r ${_binname}_signed.zip ${_appname}"

  _request_uuid=$(ssh "${OSX_HOST}" "xcrun notarytool submit ${_macos_tmpdir}/${_binname}_signed.zip --team-id \"${APPLE_TEAM}\" --apple-id \"${APPLE_ID}\" --password \"${APPLE_ID_PASSWORD}\" --no-progress --output-format json")
  _request_uuid=$(echo ${_request_uuid} | sed -e 's/.*"id":"\([^"]*\)".*/\1/')
  if ! ssh "${OSX_HOST}" "xcrun notarytool wait ${_request_uuid} --team-id \"${APPLE_TEAM}\" --apple-id \"${APPLE_ID}\" --password \"${APPLE_ID_PASSWORD}\" | grep -q status:\ Accepted"; then
    echo "Notarization failed."
    _notarization_log=$(ssh "${OSX_HOST}" "xcrun notarytool log ${_request_uuid} --team-id \"${APPLE_TEAM}\" --apple-id \"${APPLE_ID}\" --password \"${APPLE_ID_PASSWORD}\"")
    echo "${_notarization_log}"
    ssh "${OSX_HOST}" "rm -rf ${_macos_tmpdir}"
    exit 1
  else
    ssh "${OSX_HOST}" "
            cd ${_macos_tmpdir} && \
            xcrun stapler staple ${_appname} && \
            zip -r ${_binname}_stapled.zip ${_appname}"
    scp "${OSX_HOST}:${_macos_tmpdir}/${_binname}_stapled.zip" "${_reldir}/${_binname}.zip"
    ssh "${OSX_HOST}" "rm -rf ${_macos_tmpdir}"
  fi
}

sign_macos_template() {
  if [ -z "${OSX_HOST}" ]; then
    return
  fi
  _macos_tmpdir=$(ssh "${OSX_HOST}" "mktemp -d")
  _reldir="$1"
  _is_mono="$2"

  scp "${_reldir}/macos.zip" "${OSX_HOST}:${_macos_tmpdir}"
  ssh "${OSX_HOST}" "
            cd ${_macos_tmpdir} && \
            unzip macos.zip && \
            codesign --force -s - \
              --options=linker-signed \
              -v macos_template.app/Contents/MacOS/* && \
            zip -r macos_signed.zip macos_template.app"

  scp "${OSX_HOST}:${_macos_tmpdir}/macos_signed.zip" "${_reldir}/macos.zip"
  ssh "${OSX_HOST}" "rm -rf ${_macos_tmpdir}"
}

godot_version=""
templates_version=""
do_cleanup=1
make_tarball=1
build_export_templates=1
build_classical=1
build_mono=1
build_dotnet=0

build_targets=""
build_windows=0
build_linux=0
build_web=0
build_macos=0
build_android=0
build_ios=0

_build_windows_star=0
build_windows_x86_64=1
build_windows_x86_32=1
build_windows_arm64=1

_build_linux_star=0
build_linux_x86_64=1
build_linux_x86_32=1
build_linux_arm64=1
build_linux_arm32=1

build_macos_star=0
build_macos_x86_64=1
build_macos_arm64=1

_build_android_star=0
build_android_x86_64=1
build_android_x86_32=1
build_android_arm64=1
build_android_arm32=1

_build_ios_star=0
build_ios_x86_64=1
build_ios_arm64=1

while getopts "h?v:t:b:z:n-:" opt; do
  case "$opt" in
  h|\?)
    echo "Usage: $0 [OPTIONS...]"
    echo
    echo "  -v godot version (e.g: 3.2-stable) [mandatory]"
    echo "  -t templates version (e.g. 3.2.stable) [mandatory]"
    echo "  -b build target: all|classical|mono|none (default: all)"
    echo "  -z target platforms concatenated by ';' (e.g. windows;linux_x86_64;linux_x86_32)"
    echo "  --no-cleanup disable deleting pre-existing output folders (default: false)"
    echo "  --no-tarball disable generating source tarball (default: false)"
    echo "  --no-export-templates skip building export templates (default: false)"
    echo
    exit 1
    ;;
  v)
    godot_version=$OPTARG
    ;;
  t)
    templates_version=$OPTARG
    ;;
  b)
    if [ "$OPTARG" == "classical" ]; then
      build_mono=0
    elif [ "$OPTARG" == "mono" ]; then
      build_classical=0
    elif [ "$OPTARG" == "dotnet" ]; then
      build_classical=0
      build_mono=0
      build_dotnet=1
    elif [ "$OPTARG" == "none" ]; then
      build_classical=0
      build_mono=0
    fi
    ;;
  z)
    build_targets="$OPTARG"

    # Reset all targets, since we're explicitly specifying which ones to build.
    build_windows_x86_64=0
    build_windows_x86_32=0
    build_windows_arm64=0

    build_linux_x86_64=0
    build_linux_x86_32=0
    build_linux_arm64=0
    build_linux_arm32=0

    build_macos_x86_64=0
    build_macos_arm64=0

    build_android_x86_64=0
    build_android_x86_32=0
    build_android_arm64=0
    build_android_arm32=0

    build_ios_x86_64=0
    build_ios_arm64=0

    IFS=';' read -ra targets_array <<< "$build_targets"
    for target in "${targets_array[@]}"; do
      if [[ "$target" == windows ]]; then
        _build_windows_star=1
      elif [[ "$target" == windows_x86_64 ]]; then
        build_windows_x86_64=1
      elif [[ "$target" == windows_x86_32 ]]; then
        build_windows_x86_32=1
      elif [[ "$target" == windows_arm64 ]]; then
        build_windows_arm64=1
      elif [[ "$target" == linux ]]; then
        _build_linux_star=1
      elif [[ "$target" == linux_x86_64 ]]; then
        build_linux_x86_64=1
      elif [[ "$target" == linux_x86_32 ]]; then
        build_linux_x86_32=1
      elif [[ "$target" == linux_arm64 ]]; then
        build_linux_arm64=1
      elif [[ "$target" == linux_arm32 ]]; then
        build_linux_arm32=1
      elif [[ "$target" == web ]]; then
        build_web=1
      elif [[ "$target" == macos ]]; then
        _build_macos_star=1
      elif [[ "$target" == macos_x86_64 ]]; then
        build_macos_x86_64=1
      elif [[ "$target" == macos_arm_64 ]]; then
        build_macos_arm_64=1
      elif [[ "$target" == android ]]; then
        _build_android_star=1
      elif [[ "$target" == android_x86_64 ]]; then
        build_android_x86_64=1
      elif [[ "$target" == android_x86_32 ]]; then
        build_android_x86_32=1
      elif [[ "$target" == android_arm64 ]]; then
        build_android_arm64=1
      elif [[ "$target" == android_arm32 ]]; then
        build_android_arm32=1
      elif [[ "$target" == ios ]]; then
        _build_ios_star=1
      elif [[ "$target" == ios_x86_64 ]]; then
        build_ios_x86_64=1
      elif [[ "$target" == ios_arm_64 ]]; then
        build_ios_arm_64=1
      fi
    done
    ;;
  -)
    case "${OPTARG}" in
    no-cleanup)
      do_cleanup=0
      ;;
    no-tarball)
      make_tarball=0
      ;;
    no-export-templates)
      build_export_templates=0
      ;;
    *)
      if [ "$OPTERR" == 1 ] && [ "${optspec:0:1}" != ":" ]; then
        echo "Unknown option --${OPTARG}."
        exit 1
      fi
      ;;
    esac
    ;;
  esac
done

if [ -z "${godot_version}" -o -z "${templates_version}" ]; then
  echo "Mandatory argument -v or -t missing."
  exit 1
elif [[ "{$templates_version}" == *"-"* ]]; then
  echo "Templates version (-t) shouldn't contain '-'. It should use a dot to separate version from status."
  exit 1
fi

if [ "${_build_windows_star}" == 1 ]; then
  build_windows_x86_64=1
  build_windows_x86_32=1
  build_windows_arm64=1
fi
if [ "${_build_linux_star}" == 1 ]; then
  build_linux_x86_64=1
  build_linux_x86_32=1
  build_linux_arm64=1
  build_linux_arm32=1
fi
if [ "${_build_macos_star}" == 1 ]; then
  build_macos_x86_64=1
  build_macos_arm64=1
fi
if [ "${_build_android_star}" == 1 ]; then
  build_android_x86_64=1
  build_android_x86_32=1
  build_android_arm64=1
  build_android_arm32=1
fi
if [ "${_build_ios_star}" == 1 ]; then
  build_ios_x86_64=1
  build_ios_arm64=1
fi

if [ "$build_windows_x86_64" == 1 ] || [ "$build_windows_x86_32" == 1 ] || [ "$build_windows_arm64" == 1 ]; then
  build_windows=1
fi
if [ "$build_linux_x86_64" == 1 ] || [ "$build_linux_x86_32" == 1 ] || [ "$build_linux_arm64" == 1 ] || [ "$build_linux_arm32" == 1 ]; then
  build_linux=1
fi
if [ "$build_macos_x86_64" == 1 ] || [ "$build_macos_arm64" == 1 ]; then
  build_macos=1
fi
if [ "$build_android_x86_64" == 1 ] || [ "$build_android_x86_32" == 1 ] || [ "$build_android_arm64" == 1 ] || [ "$build_android_arm32" == 1 ]; then
  build_android=1
fi
if [ "$build_ios_x86_64" == 1 ] || [ "$build_ios_arm64" == 1 ]; then
  build_ios=1
fi

export webdir="${basedir}/web/${templates_version}"
export reldir="${basedir}/releases/${godot_version}"
export reldir_mono="${reldir}/mono"
export reldir_dotnet="${reldir}/dotnet"
export tmpdir="${basedir}/tmp"
export templatesdir="${tmpdir}/templates"
export templatesdir_mono="${tmpdir}/mono/templates"
export templatesdir_dotnet="${tmpdir}/dotnet/templates"

export godot_basename="Godot_v${godot_version}"

# Cleanup and setup

if [ "${do_cleanup}" == "1" ]; then

  rm -rf ${webdir}
  rm -rf ${reldir}
  rm -rf ${tmpdir}

  mkdir -p ${webdir}
  mkdir -p ${reldir}
  mkdir -p ${reldir_mono}
  mkdir -p ${reldir_dotnet}
  mkdir -p ${templatesdir}
  mkdir -p ${templatesdir_mono}
  mkdir -p ${templatesdir_dotnet}

fi

# Tarball

if [ "${make_tarball}" == "1" ]; then

  zcat godot-${godot_version}.tar.gz | xz -c > ${reldir}/godot-${godot_version}.tar.xz
  pushd ${reldir}
  sha256sum godot-${godot_version}.tar.xz > godot-${godot_version}.tar.xz.sha256
  popd

fi

# Classical

if [ "${build_classical}" == "1" ]; then

  ## Linux (Classical) ##

  if [ "${build_linux}" == "1" ]; then

    # Editor
    if [ "${build_linux_x86_64}" == "1" ]; then
      binname="${godot_basename}_linux.x86_64"
      cp out/linux/x86_64/tools/godot.linuxbsd.editor.x86_64 ${binname}
      zip -q -9 "${reldir}/${binname}.zip" ${binname}
      rm ${binname}
    fi

    if [ "${build_linux_x86_32}" == "1" ]; then
      binname="${godot_basename}_linux.x86_32"
      cp out/linux/x86_32/tools/godot.linuxbsd.editor.x86_32 ${binname}
      zip -q -9 "${reldir}/${binname}.zip" ${binname}
      rm ${binname}
    fi

    if [ "${build_linux_arm64}" == "1" ]; then
      binname="${godot_basename}_linux.arm64"
      cp out/linux/arm64/tools/godot.linuxbsd.editor.arm64 ${binname}
      zip -q -9 "${reldir}/${binname}.zip" ${binname}
      rm ${binname}
    fi

    if [ "${build_linux_arm32}" == "1" ]; then
      binname="${godot_basename}_linux.arm32"
      cp out/linux/arm32/tools/godot.linuxbsd.editor.arm32 ${binname}
      zip -q -9 "${reldir}/${binname}.zip" ${binname}
      rm ${binname}
    fi

    # ICU data
    if [ -f ${basedir}/git/thirdparty/icu4c/icudt_godot.dat ]; then
      cp ${basedir}/git/thirdparty/icu4c/icudt_godot.dat ${templatesdir}/icudt_godot.dat
    else
      echo "icudt_godot.dat" not found.
    fi

    # Templates
    if [ "${build_export_templates}" == "1" ]; then
      if [ "${build_linux_x86_64}" == "1" ]; then
        cp out/linux/x86_64/templates/godot.linuxbsd.template_release.x86_64 ${templatesdir}/linux_release.x86_64
        cp out/linux/x86_64/templates/godot.linuxbsd.template_debug.x86_64 ${templatesdir}/linux_debug.x86_64
      fi
      if [ "${build_linux_x86_32}" == "1" ]; then
        cp out/linux/x86_32/templates/godot.linuxbsd.template_release.x86_32 ${templatesdir}/linux_release.x86_32
        cp out/linux/x86_32/templates/godot.linuxbsd.template_debug.x86_32 ${templatesdir}/linux_debug.x86_32
      fi
      if [ "${build_linux_arm64}" == "1" ]; then
        cp out/linux/arm64/templates/godot.linuxbsd.template_release.arm64 ${templatesdir}/linux_release.arm64
        cp out/linux/arm64/templates/godot.linuxbsd.template_debug.arm64 ${templatesdir}/linux_debug.arm64
      fi
      if [ "${build_linux_arm32}" == "1" ]; then
        cp out/linux/arm32/templates/godot.linuxbsd.template_release.arm32 ${templatesdir}/linux_release.arm32
        cp out/linux/arm32/templates/godot.linuxbsd.template_debug.arm32 ${templatesdir}/linux_debug.arm32
      fi
    fi

  fi

  ## Windows (Classical) ##

  if [ "${build_windows}" == "1" ]; then

    # Editor
    if [ "${build_windows_x86_64}" == "1" ]; then
      binname="${godot_basename}_win64.exe"
      wrpname="${godot_basename}_win64_console.exe"
      cp out/windows/x86_64/tools/godot.windows.editor.x86_64.exe ${binname}
      sign_windows ${binname}
      cp out/windows/x86_64/tools/godot.windows.editor.x86_64.console.exe ${wrpname}
      sign_windows ${wrpname}
      zip -q -9 "${reldir}/${binname}.zip" ${binname} ${wrpname}
      rm ${binname} ${wrpname}
    fi

    if [ "${build_windows_x86_32}" == "1" ]; then
      binname="${godot_basename}_win32.exe"
      wrpname="${godot_basename}_win32_console.exe"
      cp out/windows/x86_32/tools/godot.windows.editor.x86_32.exe ${binname}
      sign_windows ${binname}
      cp out/windows/x86_32/tools/godot.windows.editor.x86_32.console.exe ${wrpname}
      sign_windows ${wrpname}
      zip -q -9 "${reldir}/${binname}.zip" ${binname} ${wrpname}
      rm ${binname} ${wrpname}
    fi

    if [ "${build_windows_arm64}" == "1" ]; then
      binname="${godot_basename}_windows_arm64.exe"
      wrpname="${godot_basename}_windows_arm64_console.exe"
      cp out/windows/arm64/tools/godot.windows.editor.arm64.llvm.exe ${binname}
      sign_windows ${binname}
      cp out/windows/arm64/tools/godot.windows.editor.arm64.llvm.console.exe ${wrpname}
      sign_windows ${wrpname}
      zip -q -9 "${reldir}/${binname}.zip" ${binname} ${wrpname}
      rm ${binname} ${wrpname}
    fi

    # Templates
    if [ "${build_export_templates}" == "1" ]; then
      if [ "${build_windows_x86_64}" == "1" ]; then
        cp out/windows/x86_64/templates/godot.windows.template_release.x86_64.exe ${templatesdir}/windows_release_x86_64.exe
        cp out/windows/x86_64/templates/godot.windows.template_debug.x86_64.exe ${templatesdir}/windows_debug_x86_64.exe
      fi
      if [ "${build_windows_x86_32}" == "1" ]; then
        cp out/windows/x86_32/templates/godot.windows.template_release.x86_32.exe ${templatesdir}/windows_release_x86_32.exe
        cp out/windows/x86_32/templates/godot.windows.template_debug.x86_32.exe ${templatesdir}/windows_debug_x86_32.exe
      fi
      if [ "${build_windows_arm64}" == "1" ]; then
        cp out/windows/arm64/templates/godot.windows.template_release.arm64.llvm.exe ${templatesdir}/windows_release_arm64.exe
        cp out/windows/arm64/templates/godot.windows.template_debug.arm64.llvm.exe ${templatesdir}/windows_debug_arm64.exe
      fi
      if [ "${build_windows_x86_64}" == "1" ]; then
        cp out/windows/x86_64/templates/godot.windows.template_release.x86_64.console.exe ${templatesdir}/windows_release_x86_64_console.exe
        cp out/windows/x86_64/templates/godot.windows.template_debug.x86_64.console.exe ${templatesdir}/windows_debug_x86_64_console.exe
      fi
      if [ "${build_windows_x86_32}" == "1" ]; then
        cp out/windows/x86_32/templates/godot.windows.template_release.x86_32.console.exe ${templatesdir}/windows_release_x86_32_console.exe
        cp out/windows/x86_32/templates/godot.windows.template_debug.x86_32.console.exe ${templatesdir}/windows_debug_x86_32_console.exe
      fi
      if [ "${build_windows_arm64}" == "1" ]; then
        cp out/windows/arm64/templates/godot.windows.template_release.arm64.llvm.console.exe ${templatesdir}/windows_release_arm64_console.exe
        cp out/windows/arm64/templates/godot.windows.template_debug.arm64.llvm.console.exe ${templatesdir}/windows_debug_arm64_console.exe
      fi
    fi

  fi

  ## macOS (Classical) ##

  if [ "${build_macos}" == "1" ]; then

    # Editor
    binname="${godot_basename}_macos.universal"
    rm -rf Godot.app
    cp -r git/misc/dist/macos_tools.app Godot.app
    mkdir -p Godot.app/Contents/MacOS
    cp out/macos/tools/godot.macos.editor.universal Godot.app/Contents/MacOS/Godot
    chmod +x Godot.app/Contents/MacOS/Godot
    zip -q -9 -r "${reldir}/${binname}.zip" Godot.app
    rm -rf Godot.app
    sign_macos ${reldir} ${binname} 0

    # Templates
    if [ "${build_export_templates}" == "1" ]; then
      rm -rf macos_template.app
      cp -r git/misc/dist/macos_template.app .
      mkdir -p macos_template.app/Contents/MacOS

      cp out/macos/templates/godot.macos.template_release.universal macos_template.app/Contents/MacOS/godot_macos_release.universal
      cp out/macos/templates/godot.macos.template_debug.universal macos_template.app/Contents/MacOS/godot_macos_debug.universal
      chmod +x macos_template.app/Contents/MacOS/godot_macos*
      zip -q -9 -r "${templatesdir}/macos.zip" macos_template.app
      rm -rf macos_template.app
      sign_macos_template ${templatesdir} 0
    fi

  fi

  ## Web (Classical) ##

  if [ "${build_web}" == "1" ]; then

    # Editor
    unzip out/web/tools/godot.web.editor.wasm32.zip -d ${webdir}/
    brotli --keep --force --quality=11 ${webdir}/*
    binname="${godot_basename}_web_editor.zip"
    cp out/web/tools/godot.web.editor.wasm32.zip ${reldir}/${binname}

    # Templates
    if [ "${build_export_templates}" == "1" ]; then
      cp out/web/templates/godot.web.template_release.wasm32.zip ${templatesdir}/web_release.zip
      cp out/web/templates/godot.web.template_debug.wasm32.zip ${templatesdir}/web_debug.zip

      cp out/web/templates/godot.web.template_release.wasm32.nothreads.zip ${templatesdir}/web_nothreads_release.zip
      cp out/web/templates/godot.web.template_debug.wasm32.nothreads.zip ${templatesdir}/web_nothreads_debug.zip

      cp out/web/templates/godot.web.template_release.wasm32.dlink.zip ${templatesdir}/web_dlink_release.zip
      cp out/web/templates/godot.web.template_debug.wasm32.dlink.zip ${templatesdir}/web_dlink_debug.zip

      cp out/web/templates/godot.web.template_release.wasm32.nothreads.dlink.zip ${templatesdir}/web_dlink_nothreads_release.zip
      cp out/web/templates/godot.web.template_debug.wasm32.nothreads.dlink.zip ${templatesdir}/web_dlink_nothreads_debug.zip
    fi

  fi

  ## Android (Classical) ##

  if [ "${build_android}" == "1" ]; then

    # Lib for direct download
    if [ "${build_export_templates}" == "1" ]; then
      cp out/android/templates/godot-lib.template_release.aar ${reldir}/godot-lib.${templates_version}.template_release.aar
    fi

    # Editor
    binname="${godot_basename}_android_editor.apk"
    cp out/android/tools/android_editor.apk ${reldir}/${binname}
    binname="${godot_basename}_android_editor_horizonos.apk"
    cp out/android/tools/android_editor_horizonos.apk ${reldir}/${binname}
    binname="${godot_basename}_android_editor_picoos.apk"
    cp out/android/tools/android_editor_picoos.apk ${reldir}/${binname}
    binname="${godot_basename}_android_editor.aab"
    cp out/android/tools/android_editor.aab ${reldir}/${binname}

    # Templates
    if [ "${build_export_templates}" == "1" ]; then
      cp out/android/templates/*.apk ${templatesdir}/
      cp out/android/templates/android_source.zip ${templatesdir}/
    fi

  fi

  ## iOS (Classical) ##

  if [ "${build_ios}" == "1" ]; then

    if [ "${build_export_templates}" == "1" ]; then
      rm -rf ios_xcode
      cp -r git/misc/dist/ios_xcode ios_xcode
      cp out/ios/templates/libgodot.ios.simulator.a ios_xcode/libgodot.ios.release.xcframework/ios-arm64_x86_64-simulator/libgodot.a
      cp out/ios/templates/libgodot.ios.debug.simulator.a ios_xcode/libgodot.ios.debug.xcframework/ios-arm64_x86_64-simulator/libgodot.a
      cp out/ios/templates/libgodot.ios.a ios_xcode/libgodot.ios.release.xcframework/ios-arm64/libgodot.a
      cp out/ios/templates/libgodot.ios.debug.a ios_xcode/libgodot.ios.debug.xcframework/ios-arm64/libgodot.a
      cp -r deps/moltenvk/MoltenVK/MoltenVK.xcframework ios_xcode/
      rm -rf ios_xcode/MoltenVK.xcframework/{macos,tvos}*
      cd ios_xcode
      zip -q -9 -r "${templatesdir}/ios.zip" *
      cd ..
      rm -rf ios_xcode
    fi

  fi

  ## Templates TPZ (Classical) ##

  if [ "${build_export_templates}" == "1" ]; then
    echo "${templates_version}" > ${templatesdir}/version.txt
    pushd ${templatesdir}/..
    zip -q -9 -r -D "${reldir}/${godot_basename}_export_templates.tpz" templates/*
    popd
  fi

  ## SHA-512 sums (Classical) ##

  pushd ${reldir}
  sha512sum [Gg]* > SHA512-SUMS.txt
  mkdir -p ${basedir}/sha512sums/${godot_version}
  cp SHA512-SUMS.txt ${basedir}/sha512sums/${godot_version}/
  popd

fi

# Mono

if [ "${build_mono}" == "1" ]; then

  ## Linux (Mono) ##

  if [ "${build_linux}" == "1" ]; then

    # Editor
    if [ "${build_linux_x86_64}" == "1" ]; then
      binbasename="${godot_basename}_mono_linux"
      mkdir -p ${binbasename}_x86_64
      cp out/linux/x86_64/tools-mono/godot.linuxbsd.editor.x86_64.mono ${binbasename}_x86_64/${binbasename}.x86_64
      cp -rp out/linux/x86_64/tools-mono/GodotSharp ${binbasename}_x86_64/
      zip -r -q -9 "${reldir_mono}/${binbasename}_x86_64.zip" ${binbasename}_x86_64
      rm -rf ${binbasename}_x86_64
    fi

    if [ "${build_linux_x86_32}" == "1" ]; then
      binbasename="${godot_basename}_mono_linux"
      mkdir -p ${binbasename}_x86_32
      cp out/linux/x86_32/tools-mono/godot.linuxbsd.editor.x86_32.mono ${binbasename}_x86_32/${binbasename}.x86_32
      cp -rp out/linux/x86_32/tools-mono/GodotSharp/ ${binbasename}_x86_32/
      zip -r -q -9 "${reldir_mono}/${binbasename}_x86_32.zip" ${binbasename}_x86_32
      rm -rf ${binbasename}_x86_32
    fi

    if [ "${build_linux_arm64}" == "1" ]; then
      binbasename="${godot_basename}_mono_linux"
      mkdir -p ${binbasename}_arm64
      cp out/linux/arm64/tools-mono/godot.linuxbsd.editor.arm64.mono ${binbasename}_arm64/${binbasename}.arm64
      cp -rp out/linux/arm64/tools-mono/GodotSharp/ ${binbasename}_arm64/
      zip -r -q -9 "${reldir_mono}/${binbasename}_arm64.zip" ${binbasename}_arm64
      rm -rf ${binbasename}_arm64
    fi

    if [ "${build_linux_arm32}" == "1" ]; then
      binbasename="${godot_basename}_mono_linux"
      mkdir -p ${binbasename}_arm32
      cp out/linux/arm32/tools-mono/godot.linuxbsd.editor.arm32.mono ${binbasename}_arm32/${binbasename}.arm32
      cp -rp out/linux/arm32/tools-mono/GodotSharp/ ${binbasename}_arm32/
      zip -r -q -9 "${reldir_mono}/${binbasename}_arm32.zip" ${binbasename}_arm32
      rm -rf ${binbasename}_arm32
    fi

    # ICU data
    if [ -f ${basedir}/git/thirdparty/icu4c/icudt_godot.dat ]; then
      cp ${basedir}/git/thirdparty/icu4c/icudt_godot.dat ${templatesdir_mono}/icudt_godot.dat
    else
      echo "icudt_godot.dat" not found.
    fi

    # Templates
    if [ "${build_export_templates}" == "1" ]; then
      if [ "${build_linux_x86_64}" == "1" ]; then
        cp out/linux/x86_64/templates-mono/godot.linuxbsd.template_debug.x86_64.mono ${templatesdir_mono}/linux_debug.x86_64
        cp out/linux/x86_64/templates-mono/godot.linuxbsd.template_release.x86_64.mono ${templatesdir_mono}/linux_release.x86_64
      fi
      if [ "${build_linux_x86_32}" == "1" ]; then
        cp out/linux/x86_32/templates-mono/godot.linuxbsd.template_debug.x86_32.mono ${templatesdir_mono}/linux_debug.x86_32
        cp out/linux/x86_32/templates-mono/godot.linuxbsd.template_release.x86_32.mono ${templatesdir_mono}/linux_release.x86_32
      fi
      if [ "${build_linux_arm64}" == "1" ]; then
        cp out/linux/arm64/templates-mono/godot.linuxbsd.template_debug.arm64.mono ${templatesdir_mono}/linux_debug.arm64
        cp out/linux/arm64/templates-mono/godot.linuxbsd.template_release.arm64.mono ${templatesdir_mono}/linux_release.arm64
      fi
      if [ "${build_linux_arm32}" == "1" ]; then
        cp out/linux/arm32/templates-mono/godot.linuxbsd.template_debug.arm32.mono ${templatesdir_mono}/linux_debug.arm32
        cp out/linux/arm32/templates-mono/godot.linuxbsd.template_release.arm32.mono ${templatesdir_mono}/linux_release.arm32
      fi
    fi

  fi

  ## Windows (Mono) ##

  if [ "${build_windows}" == "1" ]; then

    # Editor
    if [ "${build_windows_x86_64}" == "1" ]; then
      binname="${godot_basename}_mono_win64"
      wrpname="${godot_basename}_mono_win64_console"
      mkdir -p ${binname}
      cp out/windows/x86_64/tools-mono/godot.windows.editor.x86_64.mono.exe ${binname}/${binname}.exe
      sign_windows ${binname}/${binname}.exe
      cp -rp out/windows/x86_64/tools-mono/GodotSharp ${binname}/
      cp out/windows/x86_64/tools-mono/godot.windows.editor.x86_64.mono.console.exe ${binname}/${wrpname}.exe
      sign_windows ${binname}/${wrpname}.exe
      zip -r -q -9 "${reldir_mono}/${binname}.zip" ${binname}
      rm -rf ${binname}
    fi

    if [ "${build_windows_x86_32}" == "1" ]; then
      binname="${godot_basename}_mono_win32"
      wrpname="${godot_basename}_mono_win32_console"
      mkdir -p ${binname}
      cp out/windows/x86_32/tools-mono/godot.windows.editor.x86_32.mono.exe ${binname}/${binname}.exe
      sign_windows ${binname}/${binname}.exe
      cp -rp out/windows/x86_32/tools-mono/GodotSharp ${binname}/
      cp out/windows/x86_32/tools-mono/godot.windows.editor.x86_32.mono.console.exe ${binname}/${wrpname}.exe
      sign_windows ${binname}/${wrpname}.exe
      zip -r -q -9 "${reldir_mono}/${binname}.zip" ${binname}
      rm -rf ${binname}
    fi

    if [ "${build_windows_arm64}" == "1" ]; then
      binname="${godot_basename}_mono_windows_arm64"
      wrpname="${godot_basename}_mono_windows_arm64_console"
      mkdir -p ${binname}
      cp out/windows/arm64/tools-mono/godot.windows.editor.arm64.llvm.mono.exe ${binname}/${binname}.exe
      sign_windows ${binname}/${binname}.exe
      cp -rp out/windows/arm64/tools-mono/GodotSharp ${binname}/
      cp out/windows/arm64/tools-mono/godot.windows.editor.arm64.llvm.mono.console.exe ${binname}/${wrpname}.exe
      sign_windows ${binname}/${wrpname}.exe
      zip -r -q -9 "${reldir_mono}/${binname}.zip" ${binname}
      rm -rf ${binname}
    fi

    # Templates
    if [ "${build_export_templates}" == "1" ]; then
      if [ "${build_windows_x86_64}" == "1" ]; then
        cp out/windows/x86_64/templates-mono/godot.windows.template_debug.x86_64.mono.exe ${templatesdir_mono}/windows_debug_x86_64.exe
        cp out/windows/x86_64/templates-mono/godot.windows.template_release.x86_64.mono.exe ${templatesdir_mono}/windows_release_x86_64.exe
      fi
      if [ "${build_windows_x86_32}" == "1" ]; then
        cp out/windows/x86_32/templates-mono/godot.windows.template_debug.x86_32.mono.exe ${templatesdir_mono}/windows_debug_x86_32.exe
        cp out/windows/x86_32/templates-mono/godot.windows.template_release.x86_32.mono.exe ${templatesdir_mono}/windows_release_x86_32.exe
      fi
      if [ "${build_windows_arm64}" == "1" ]; then
        cp out/windows/arm64/templates-mono/godot.windows.template_debug.arm64.llvm.mono.exe ${templatesdir_mono}/windows_debug_arm64.exe
        cp out/windows/arm64/templates-mono/godot.windows.template_release.arm64.llvm.mono.exe ${templatesdir_mono}/windows_release_arm64.exe
      fi
      if [ "${build_windows_x86_64}" == "1" ]; then
        cp out/windows/x86_64/templates-mono/godot.windows.template_debug.x86_64.mono.console.exe ${templatesdir_mono}/windows_debug_x86_64_console.exe
        cp out/windows/x86_64/templates-mono/godot.windows.template_release.x86_64.mono.console.exe ${templatesdir_mono}/windows_release_x86_64_console.exe
      fi
      if [ "${build_windows_x86_32}" == "1" ]; then
        cp out/windows/x86_32/templates-mono/godot.windows.template_debug.x86_32.mono.console.exe ${templatesdir_mono}/windows_debug_x86_32_console.exe
        cp out/windows/x86_32/templates-mono/godot.windows.template_release.x86_32.mono.console.exe ${templatesdir_mono}/windows_release_x86_32_console.exe
      fi
      if [ "${build_windows_arm64}" == "1" ]; then
        cp out/windows/arm64/templates-mono/godot.windows.template_debug.arm64.llvm.mono.console.exe ${templatesdir_mono}/windows_debug_arm64_console.exe
        cp out/windows/arm64/templates-mono/godot.windows.template_release.arm64.llvm.mono.console.exe ${templatesdir_mono}/windows_release_arm64_console.exe
      fi
    fi

  fi

  ## macOS (Mono) ##

  if [ "${build_macos}" == "1" ]; then

    # Editor
    binname="${godot_basename}_mono_macos.universal"
    rm -rf Godot_mono.app
    cp -r git/misc/dist/macos_tools.app Godot_mono.app
    mkdir -p Godot_mono.app/Contents/{MacOS,Resources}
    cp out/macos/tools-mono/godot.macos.editor.universal.mono Godot_mono.app/Contents/MacOS/Godot
    cp -rp out/macos/tools-mono/GodotSharp Godot_mono.app/Contents/Resources/GodotSharp
    chmod +x Godot_mono.app/Contents/MacOS/Godot
    zip -q -9 -r "${reldir_mono}/${binname}.zip" Godot_mono.app
    rm -rf Godot_mono.app
    sign_macos ${reldir_mono} ${binname} 1

    # Templates
    if [ "${build_export_templates}" == "1" ]; then
      rm -rf macos_template.app
      cp -r git/misc/dist/macos_template.app .
      mkdir -p macos_template.app/Contents/{MacOS,Resources}
      cp out/macos/templates-mono/godot.macos.template_debug.universal.mono macos_template.app/Contents/MacOS/godot_macos_debug.universal
      cp out/macos/templates-mono/godot.macos.template_release.universal.mono macos_template.app/Contents/MacOS/godot_macos_release.universal
      chmod +x macos_template.app/Contents/MacOS/godot_macos*
      zip -q -9 -r "${templatesdir_mono}/macos.zip" macos_template.app
      rm -rf macos_template.app
      sign_macos_template ${templatesdir_mono} 1
    fi

  fi

  ## Android (Mono) ##

  if [ "${build_android}" == "1" ]; then

    if [ "${build_export_templates}" == "1" ]; then
      # Lib for direct download
      cp out/android/templates-mono/godot-lib.template_release.aar ${reldir_mono}/godot-lib.${templates_version}.mono.template_release.aar

      # Templates
      cp out/android/templates-mono/*.apk ${templatesdir_mono}/
      cp out/android/templates-mono/android_source.zip ${templatesdir_mono}/
    fi

  fi

  ## iOS (Mono) ##

  if [ "${build_ios}" == "1" ]; then

    if [ "${build_export_templates}" == "1" ]; then
      rm -rf ios_xcode
      cp -r git/misc/dist/ios_xcode ios_xcode
      cp out/ios/templates-mono/libgodot.ios.simulator.a ios_xcode/libgodot.ios.release.xcframework/ios-arm64_x86_64-simulator/libgodot.a
      cp out/ios/templates-mono/libgodot.ios.debug.simulator.a ios_xcode/libgodot.ios.debug.xcframework/ios-arm64_x86_64-simulator/libgodot.a
      cp out/ios/templates-mono/libgodot.ios.a ios_xcode/libgodot.ios.release.xcframework/ios-arm64/libgodot.a
      cp out/ios/templates-mono/libgodot.ios.debug.a ios_xcode/libgodot.ios.debug.xcframework/ios-arm64/libgodot.a
      cp -r deps/moltenvk/MoltenVK/MoltenVK.xcframework ios_xcode/
      rm -rf ios_xcode/MoltenVK.xcframework/{macos,tvos}*
      cd ios_xcode
      zip -q -9 -r "${templatesdir_mono}/ios.zip" *
      cd ..
      rm -rf ios_xcode
    fi

  fi

  # No .NET support for those platforms yet.

  if false; then

  ## Web (Mono) ##

  if [ "${build_web}" == "1" ]; then

    # Templates
    if [ "${build_export_templates}" == "1" ]; then
      cp out/web/templates-mono/godot.web.template_debug.wasm32.mono.zip ${templatesdir_mono}/web_debug.zip
      cp out/web/templates-mono/godot.web.template_release.wasm32.mono.zip ${templatesdir_mono}/web_release.zip
    fi

  fi

  fi

  ## Templates TPZ (Mono) ##

  if [ "${build_export_templates}" == "1" ]; then
    echo "${templates_version}.mono" > ${templatesdir_mono}/version.txt
    pushd ${templatesdir_mono}/..
    zip -q -9 -r -D "${reldir_mono}/${godot_basename}_mono_export_templates.tpz" templates/*
    popd
  fi

  ## SHA-512 sums (Mono) ##

  pushd ${reldir_mono}
  sha512sum [Gg]* >> SHA512-SUMS.txt
  mkdir -p ${basedir}/sha512sums/${godot_version}/mono
  cp SHA512-SUMS.txt ${basedir}/sha512sums/${godot_version}/mono/
  popd

fi

# .NET

if [ "${build_dotnet}" == "1" ]; then

  ## Linux (.NET) ##

  if [ "${build_linux}" == "1" ]; then

    # Editor
    if [ "${build_linux_x86_64}" == "1" ]; then
      binbasename="${godot_basename}_dotnet_linux"
      mkdir -p ${binbasename}_x86_64
      cp out/linux/x86_64/tools-dotnet/godot.linuxbsd.editor.x86_64.dotnet ${binbasename}_x86_64/${binbasename}.x86_64
      zip -r -q -9 "${reldir_dotnet}/${binbasename}_x86_64.zip" ${binbasename}_x86_64
      rm -rf ${binbasename}_x86_64
    fi

    if [ "${build_linux_x86_32}" == "1" ]; then
      binbasename="${godot_basename}_dotnet_linux"
      mkdir -p ${binbasename}_x86_32
      cp out/linux/x86_32/tools-dotnet/godot.linuxbsd.editor.x86_32.dotnet ${binbasename}_x86_32/${binbasename}.x86_32
      zip -r -q -9 "${reldir_dotnet}/${binbasename}_x86_32.zip" ${binbasename}_x86_32
      rm -rf ${binbasename}_x86_32
    fi

    if [ "${build_linux_arm64}" == "1" ]; then
      binbasename="${godot_basename}_dotnet_linux"
      mkdir -p ${binbasename}_arm64
      cp out/linux/arm64/tools-dotnet/godot.linuxbsd.editor.arm64.dotnet ${binbasename}_arm64/${binbasename}.arm64
      zip -r -q -9 "${reldir_dotnet}/${binbasename}_arm64.zip" ${binbasename}_arm64
      rm -rf ${binbasename}_arm64
    fi

    if [ "${build_linux_arm32}" == "1" ]; then
      binbasename="${godot_basename}_dotnet_linux"
      mkdir -p ${binbasename}_arm32
      cp out/linux/arm32/tools-dotnet/godot.linuxbsd.editor.arm32.dotnet ${binbasename}_arm32/${binbasename}.arm32
      zip -r -q -9 "${reldir_dotnet}/${binbasename}_arm32.zip" ${binbasename}_arm32
      rm -rf ${binbasename}_arm32
    fi

    # ICU data
    if [ -f ${basedir}/git/thirdparty/icu4c/icudt_godot.dat ]; then
      cp ${basedir}/git/thirdparty/icu4c/icudt_godot.dat ${templatesdir_dotnet}/icudt_godot.dat
    else
      echo "icudt_godot.dat" not found.
    fi

    # Templates
    if [ "${build_export_templates}" == "1" ]; then
      if [ "${build_linux_x86_64}" == "1" ]; then
        cp out/linux/x86_64/templates-dotnet/godot.linuxbsd.template_debug.x86_64.dotnet ${templatesdir_dotnet}/linux_debug.x86_64
        cp out/linux/x86_64/templates-dotnet/godot.linuxbsd.template_release.x86_64.dotnet ${templatesdir_dotnet}/linux_release.x86_64
      fi
      if [ "${build_linux_x86_32}" == "1" ]; then
        cp out/linux/x86_32/templates-dotnet/godot.linuxbsd.template_debug.x86_32.dotnet ${templatesdir_dotnet}/linux_debug.x86_32
        cp out/linux/x86_32/templates-dotnet/godot.linuxbsd.template_release.x86_32.dotnet ${templatesdir_dotnet}/linux_release.x86_32
      fi
      if [ "${build_linux_arm64}" == "1" ]; then
        cp out/linux/arm64/templates-dotnet/godot.linuxbsd.template_debug.arm64.dotnet ${templatesdir_dotnet}/linux_debug.arm64
        cp out/linux/arm64/templates-dotnet/godot.linuxbsd.template_release.arm64.dotnet ${templatesdir_dotnet}/linux_release.arm64
      fi
      if [ "${build_linux_arm32}" == "1" ]; then
        cp out/linux/arm32/templates-dotnet/godot.linuxbsd.template_debug.arm32.dotnet ${templatesdir_dotnet}/linux_debug.arm32
        cp out/linux/arm32/templates-dotnet/godot.linuxbsd.template_release.arm32.dotnet ${templatesdir_dotnet}/linux_release.arm32
      fi
    fi

  fi

  ## Windows (.NET) ##

  if [ "${build_windows}" == "1" ]; then

    # Editor
    if [ "${build_windows_x86_64}" == "1" ]; then
      binname="${godot_basename}_dotnet_win64"
      wrpname="${godot_basename}_dotnet_win64_console"
      mkdir -p ${binname}
      cp out/windows/x86_64/tools-dotnet/godot.windows.editor.x86_64.dotnet.exe ${binname}/${binname}.exe
      sign_windows ${binname}/${binname}.exe
      cp out/windows/x86_64/tools-dotnet/godot.windows.editor.x86_64.dotnet.console.exe ${binname}/${wrpname}.exe
      sign_windows ${binname}/${wrpname}.exe
      zip -r -q -9 "${reldir_dotnet}/${binname}.zip" ${binname}
      rm -rf ${binname}
    fi

    if [ "${build_windows_x86_32}" == "1" ]; then
      binname="${godot_basename}_dotnet_win32"
      wrpname="${godot_basename}_dotnet_win32_console"
      mkdir -p ${binname}
      cp out/windows/x86_32/tools-dotnet/godot.windows.editor.x86_32.dotnet.exe ${binname}/${binname}.exe
      sign_windows ${binname}/${binname}.exe
      cp out/windows/x86_32/tools-dotnet/godot.windows.editor.x86_32.dotnet.console.exe ${binname}/${wrpname}.exe
      sign_windows ${binname}/${wrpname}.exe
      zip -r -q -9 "${reldir_dotnet}/${binname}.zip" ${binname}
      rm -rf ${binname}
    fi

    if [ "${build_windows_arm64}" == "1" ]; then
      binname="${godot_basename}_dotnet_windows_arm64"
      wrpname="${godot_basename}_dotnet_windows_arm64_console"
      mkdir -p ${binname}
      cp out/windows/arm64/tools-dotnet/godot.windows.editor.arm64.llvm.dotnet.exe ${binname}/${binname}.exe
      sign_windows ${binname}/${binname}.exe
      cp out/windows/arm64/tools-dotnet/godot.windows.editor.arm64.llvm.dotnet.console.exe ${binname}/${wrpname}.exe
      sign_windows ${binname}/${wrpname}.exe
      zip -r -q -9 "${reldir_dotnet}/${binname}.zip" ${binname}
      rm -rf ${binname}
    fi

    # Templates
    if [ "${build_export_templates}" == "1" ]; then
      if [ "${build_windows_x86_64}" == "1" ]; then
        cp out/windows/x86_64/templates-dotnet/godot.windows.template_debug.x86_64.dotnet.exe ${templatesdir_dotnet}/windows_debug_x86_64.exe
        cp out/windows/x86_64/templates-dotnet/godot.windows.template_release.x86_64.dotnet.exe ${templatesdir_dotnet}/windows_release_x86_64.exe
      fi
      if [ "${build_windows_x86_32}" == "1" ]; then
        cp out/windows/x86_32/templates-dotnet/godot.windows.template_debug.x86_32.dotnet.exe ${templatesdir_dotnet}/windows_debug_x86_32.exe
        cp out/windows/x86_32/templates-dotnet/godot.windows.template_release.x86_32.dotnet.exe ${templatesdir_dotnet}/windows_release_x86_32.exe
      fi
      if [ "${build_windows_arm64}" == "1" ]; then
        cp out/windows/arm64/templates-dotnet/godot.windows.template_debug.arm64.llvm.dotnet.exe ${templatesdir_dotnet}/windows_debug_arm64.exe
        cp out/windows/arm64/templates-dotnet/godot.windows.template_release.arm64.llvm.dotnet.exe ${templatesdir_dotnet}/windows_release_arm64.exe
      fi
      if [ "${build_windows_x86_64}" == "1" ]; then
        cp out/windows/x86_64/templates-dotnet/godot.windows.template_debug.x86_64.dotnet.console.exe ${templatesdir_dotnet}/windows_debug_x86_64_console.exe
        cp out/windows/x86_64/templates-dotnet/godot.windows.template_release.x86_64.dotnet.console.exe ${templatesdir_dotnet}/windows_release_x86_64_console.exe
      fi
      if [ "${build_windows_x86_32}" == "1" ]; then
        cp out/windows/x86_32/templates-dotnet/godot.windows.template_debug.x86_32.dotnet.console.exe ${templatesdir_dotnet}/windows_debug_x86_32_console.exe
        cp out/windows/x86_32/templates-dotnet/godot.windows.template_release.x86_32.dotnet.console.exe ${templatesdir_dotnet}/windows_release_x86_32_console.exe
      fi
      if [ "${build_windows_arm64}" == "1" ]; then
        cp out/windows/arm64/templates-dotnet/godot.windows.template_debug.arm64.llvm.dotnet.console.exe ${templatesdir_dotnet}/windows_debug_arm64_console.exe
        cp out/windows/arm64/templates-dotnet/godot.windows.template_release.arm64.llvm.dotnet.console.exe ${templatesdir_dotnet}/windows_release_arm64_console.exe
      fi
    fi

  fi

  ## macOS (.NET) ##

  if [ "${build_macos}" == "1" ]; then

    # Editor
    binname="${godot_basename}_dotnet_macos.universal"
    rm -rf Godot_dotnet.app
    cp -r git/misc/dist/macos_tools.app Godot_dotnet.app
    mkdir -p Godot_dotnet.app/Contents/{MacOS,Resources}
    cp out/macos/tools-dotnet/godot.macos.editor.universal.dotnet Godot_dotnet.app/Contents/MacOS/Godot
    chmod +x Godot_dotnet.app/Contents/MacOS/Godot
    zip -q -9 -r "${reldir_dotnet}/${binname}.zip" Godot_dotnet.app
    rm -rf Godot_dotnet.app
    sign_macos ${reldir_dotnet} ${binname} 1

    # Templates
    if [ "${build_export_templates}" == "1" ]; then
      rm -rf macos_template.app
      cp -r git/misc/dist/macos_template.app .
      mkdir -p macos_template.app/Contents/{MacOS,Resources}
      cp out/macos/templates-dotnet/godot.macos.template_debug.universal.dotnet macos_template.app/Contents/MacOS/godot_macos_debug.universal
      cp out/macos/templates-dotnet/godot.macos.template_release.universal.dotnet macos_template.app/Contents/MacOS/godot_macos_release.universal
      chmod +x macos_template.app/Contents/MacOS/godot_macos*
      zip -q -9 -r "${templatesdir_dotnet}/macos.zip" macos_template.app
      rm -rf macos_template.app
      sign_macos_template ${templatesdir_dotnet} 1
    fi

  fi

  ## Android (.NET) ##

  if [ "${build_android}" == "1" ]; then

    if [ "${build_export_templates}" == "1" ]; then
      # Lib for direct download
      cp out/android/templates-dotnet/godot-lib.template_release.aar ${reldir_dotnet}/godot-lib.${templates_version}.dotnet.template_release.aar

      # Templates
      cp out/android/templates-dotnet/*.apk ${templatesdir_dotnet}/
      cp out/android/templates-dotnet/android_source.zip ${templatesdir_dotnet}/
    fi

  fi

  ## iOS (.NET) ##

  if [ "${build_ios}" == "1" ]; then

    if [ "${build_export_templates}" == "1" ]; then
      rm -rf ios_xcode
      cp -r git/misc/dist/ios_xcode ios_xcode
      cp out/ios/templates-dotnet/libgodot.ios.simulator.a ios_xcode/libgodot.ios.release.xcframework/ios-arm64_x86_64-simulator/libgodot.a
      cp out/ios/templates-dotnet/libgodot.ios.debug.simulator.a ios_xcode/libgodot.ios.debug.xcframework/ios-arm64_x86_64-simulator/libgodot.a
      cp out/ios/templates-dotnet/libgodot.ios.a ios_xcode/libgodot.ios.release.xcframework/ios-arm64/libgodot.a
      cp out/ios/templates-dotnet/libgodot.ios.debug.a ios_xcode/libgodot.ios.debug.xcframework/ios-arm64/libgodot.a
      cp -r deps/moltenvk/MoltenVK/MoltenVK.xcframework ios_xcode/
      rm -rf ios_xcode/MoltenVK.xcframework/{macos,tvos}*
      cd ios_xcode
      zip -q -9 -r "${templatesdir_dotnet}/ios.zip" *
      cd ..
      rm -rf ios_xcode
    fi

  fi

  # No .NET support for those platforms yet.

  if false; then

  ## Web (.NET) ##

  if [ "${build_web}" == "1" ]; then

    # Templates
    if [ "${build_export_templates}" == "1" ]; then
      cp out/web/templates-dotnet/godot.web.template_debug.wasm32.dotnet.zip ${templatesdir_dotnet}/web_debug.zip
      cp out/web/templates-dotnet/godot.web.template_release.wasm32.dotnet.zip ${templatesdir_dotnet}/web_release.zip
    fi

  fi

  fi

  ## Templates TPZ (.NET) ##

  if [ "${build_export_templates}" == "1" ]; then
    echo "${templates_version}.dotnet" > ${templatesdir_dotnet}/version.txt
    pushd ${templatesdir_dotnet}/..
    zip -q -9 -r -D "${reldir_dotnet}/${godot_basename}_dotnet_export_templates.tpz" templates/*
    popd
  fi

  ## SHA-512 sums (.NET) ##

  pushd ${reldir_dotnet}
  sha512sum [Gg]* >> SHA512-SUMS.txt
  mkdir -p ${basedir}/sha512sums/${godot_version}/dotnet
  cp SHA512-SUMS.txt ${basedir}/sha512sums/${godot_version}/dotnet/
  popd

fi

echo "All editor binaries and templates prepared successfully for release"
