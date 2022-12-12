#!/bin/sh
set -exou

# Clean config for dirty builds
# -----------------------------
if [[ -d qt-build ]]; then
  rm -rf qt-build
fi

mkdir qt-build
pushd qt-build

USED_BUILD_PREFIX=${BUILD_PREFIX:-${PREFIX}}
MAKE_JOBS=$CPU_COUNT
export NINJAFLAGS="-j${MAKE_JOBS}"

# For QDoc
export LLVM_INSTALL_DIR=${PREFIX}

# Remove the full path from CXX etc. If we don't do this
# then the full path at build time gets put into
# mkspecs/qmodule.pri and qmake attempts to use this.
export AR=$(basename ${AR})
export RANLIB=$(basename ${RANLIB})
export STRIP=$(basename ${STRIP})
export OBJDUMP=$(basename ${OBJDUMP})
export CC=$(basename ${CC})
export CXX=$(basename ${CXX})

if [[ $(uname) == "Linux" ]]; then
    ln -s ${GXX} g++ || true
    ln -s ${GCC} gcc || true
    # Needed for -ltcg, it we merge build and host again, change to ${PREFIX}
    ln -s ${USED_BUILD_PREFIX}/bin/${HOST}-gcc-ar gcc-ar || true

    export LD=${GXX}
    export CC=${GCC}
    export CXX=${GXX}
    export PKG_CONFIG_PATH="$PKG_CONFIG_PATH:/usr/lib64/pkgconfig/"
    chmod +x g++ gcc gcc-ar
    export PATH=${PWD}:${PATH}

    qmake -set prefix $PREFIX
    qmake QMAKE_LIBDIR=${PREFIX}/lib \
        QMAKE_LFLAGS+="-Wl,-rpath,$PREFIX/lib -Wl,-rpath-link,$PREFIX/lib -L$PREFIX/lib" \
        INCLUDEPATH+="${PREFIX}/include" \
        PKG_CONFIG_EXECUTABLE=$(which pkg-config) \
        ..

    CPATH=$PREFIX/include:$BUILD_PREFIX/src/core/api make -j$CPU_COUNT
    make install
fi

if [[ ${HOST} =~ .*darwin.* ]]; then
    # Some test runs 'clang -v', but I do not want to add it as a requirement just for that.
    ln -s "${CXX}" ${HOST}-clang || true
    # For ltcg we cannot use libtool (or at least not the macOS 10.9 system one) due to lack of LLVM bitcode support.
    ln -s "${LIBTOOL}" libtool || true
    # Just in-case our strip is better than the system one.
    ln -s "${STRIP}" strip || true
    chmod +x ${HOST}-clang libtool strip
    # Qt passes clang flags to LD (e.g. -stdlib=c++)
    export LD=${CXX}
    PATH=${PWD}:${PATH}

    PLATFORM="-sdk macosx${MACOSX_SDK_VERSION:-10.14}"
    if [[ "${target_platform}" == "osx-arm64" ]]; then
      PLATFORM="-device-option QMAKE_APPLE_DEVICE_ARCHS=arm64 -sdk macosx${MACOSX_SDK_VERSION:-11.0}"
    fi

    if [[ "${CONDA_BUILD_CROSS_COMPILATION:-}" == "1" ]]; then
      # GLib pulls arm64 python as part of its distribution, which cannot be executed on x86_64 CIs
      CONDA_SUBDIR="osx-64" conda create -y --prefix "${SRC_DIR}/osx_64_python" python zstd -c conda-forge
      export PATH="${SRC_DIR}/osx_64_python/bin":$PATH

      # The CROSS_COMPILE option can be used if the x86_64 compiler is used. However, since the arm64
      # cross compiler can also produce x86_64 binaries, there is no need for it. This is commented out
      # in order to reference how it could be used.
      # PLATFORM="$PLATFORM -device-option CROSS_COMPILE=${HOST}-"

      # llvm-config from host env is tried by configure
      # Move the build prefix one to host prefix
      rm $PREFIX/bin/llvm-config
      cp $BUILD_PREFIX/bin/llvm-config $PREFIX/bin/llvm-config
      rm $BUILD_PREFIX/bin/llvm-config

      # We need to merge both libc++ and libclang in order to compile QDoc to have both x86_64 and arm64
      # compatibility
      lipo -create $BUILD_PREFIX/lib/libc++.dylib $PREFIX/lib/libc++.dylib -output $PREFIX/lib/libc++.dylib
      lipo -create $BUILD_PREFIX/lib/libclang.dylib $PREFIX/lib/libclang.dylib -output $PREFIX/lib/libclang.dylib
    fi

    # Set QMake prefix to $PREFIX
    qmake -set prefix $PREFIX

    # sed -i '' -e 's/-Werror//' $PREFIX/mkspecs/features/qt_module_headers.prf

    qmake QMAKE_LIBDIR=${PREFIX}/lib \
        INCLUDEPATH+="${PREFIX}/include" \
        CONFIG+="warn_off" \
        QMAKE_CFLAGS_WARN_ON="-w" \
        QMAKE_CXXFLAGS_WARN_ON="-w" \
        QMAKE_CFLAGS+="-Wno-everything" \
        QMAKE_CXXFLAGS+="-Wno-everything" \
        QMAKE_LFLAGS+="-Wno-everything -Wl,-rpath,$PREFIX/lib -L$PREFIX/lib" \
        PKG_CONFIG_EXECUTABLE=$(which pkg-config) \
        ..

    make -j$CPU_COUNT
    make install
fi

# Post build setup
# ----------------
# Remove static libraries that are not part of the Qt SDK.
pushd "${PREFIX}"/lib > /dev/null
    find . -name "*.a" -and -not -name "libQt*" -exec rm -f {} \;
popd > /dev/null
