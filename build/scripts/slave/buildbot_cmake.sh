#!/bin/bash

set -x
set -e
set -u

HERE="$(dirname $0)"
. ${HERE}/buildbot_functions.sh

ROOT=`pwd`
PLATFORM=`uname`
ARCH=`uname -m`
export PATH="/usr/local/bin:$PATH"

if [ "$BUILDBOT_CLOBBER" != "" ]; then
  echo @@@BUILD_STEP clobber@@@
  rm -rf llvm
  rm -rf clang_build
fi

# Always clobber bootstrap build trees.
rm -rf compiler_rt_build
rm -rf llvm_build64
rm -rf llvm_build_ninja

SUPPORTS_32_BITS=${SUPPORTS_32_BITS:-1}
MAKE_JOBS=${MAX_MAKE_JOBS:-16}
LLVM_CHECKOUT=$ROOT/llvm
COMPILER_RT_CHECKOUT=$LLVM_CHECKOUT/projects/compiler-rt
CMAKE_COMMON_OPTIONS="-DLLVM_ENABLE_ASSERTIONS=ON"
ENABLE_LIBCXX_FLAG=
if [ "$PLATFORM" == "Darwin" ]; then
  CMAKE_COMMON_OPTIONS="${CMAKE_COMMON_OPTIONS} -DPYTHON_EXECUTABLE=/usr/bin/python"
  ENABLE_LIBCXX_FLAG="-DLLVM_ENABLE_LIBCXX=ON"
fi

echo @@@BUILD_STEP update@@@
buildbot_update


echo @@@BUILD_STEP lint@@@
CHECK_LINT=${COMPILER_RT_CHECKOUT}/lib/sanitizer_common/scripts/check_lint.sh
(LLVM_CHECKOUT=${LLVM_CHECKOUT} ${CHECK_LINT}) || echo @@@STEP_WARNINGS@@@

# Use both gcc and just-built Clang as a host compiler for sanitizer tests.
# Assume that self-hosted build tree should compile with -Werror.
echo @@@BUILD_STEP build fresh clang@@@
if [ ! -d clang_build ]; then
  mkdir clang_build
fi
(cd clang_build && cmake -DCMAKE_BUILD_TYPE=Release \
    ${CMAKE_COMMON_OPTIONS} $LLVM_CHECKOUT)
(cd clang_build && make clang -j$MAKE_JOBS) || echo @@@STEP_FAILURE@@@

# If we're building with libcxx, install the headers to clang_build/include.
if [ ! -z ${ENABLE_LIBCXX_FLAG} ]; then
(cd clang_build && make -C ${LLVM_CHECKOUT}/projects/libcxx installheaders \
  HEADER_DIR=${PWD}/include) || echo @@@STEP_FAILURE@@@
fi

# Do a sanity check on Linux: build and test sanitizers using gcc as a host
# compiler.
if [ "$PLATFORM" == "Linux" ]; then
  echo @@@BUILD_STEP run sanitizer tests in gcc build@@@
  (cd clang_build && make -j$MAKE_JOBS check-sanitizer) || echo @@@STEP_FAILURE@@@
  (cd clang_build && make -j$MAKE_JOBS check-asan) || echo @@@STEP_FAILURE@@@
  (cd clang_build && make -j$MAKE_JOBS check-lsan) || echo @@@STEP_FAILURE@@@
  (cd clang_build && make -j$MAKE_JOBS check-msan) || echo @@@STEP_FAILURE@@@
  (cd clang_build && make -j$MAKE_JOBS check-tsan) || echo @@@STEP_FAILURE@@@
  (cd clang_build && make -j$MAKE_JOBS check-ubsan) || echo @@@STEP_WARNINGS@@@
  (cd clang_build && make -j$MAKE_JOBS check-dfsan) || echo @@@STEP_WARNINGS@@@
fi

### From now on we use just-built Clang as a host compiler ###
CLANG_PATH=${ROOT}/clang_build/bin
# Build self-hosted tree with fresh Clang and -Werror.
CMAKE_CLANG_OPTIONS="${CMAKE_COMMON_OPTIONS} -DLLVM_ENABLE_WERROR=ON -DCMAKE_C_COMPILER=${CLANG_PATH}/clang -DCMAKE_CXX_COMPILER=${CLANG_PATH}/clang++"
BUILD_TYPE=Release

echo @@@BUILD_STEP bootstrap clang@@@
if [ ! -d llvm_build64 ]; then
  mkdir llvm_build64
fi
(cd llvm_build64 && cmake -DCMAKE_BUILD_TYPE=$BUILD_TYPE \
    ${CMAKE_CLANG_OPTIONS} -DLLVM_BUILD_EXTERNAL_COMPILER_RT=ON \
    ${ENABLE_LIBCXX_FLAG} $LLVM_CHECKOUT)
# First, build only Clang.
(cd llvm_build64 && make -j$MAKE_JOBS clang) || echo @@@STEP_FAILURE@@@

# If needed, install the headers to clang_build/include.
if [ ! -z ${ENABLE_LIBCXX_FLAG} ]; then
(cd llvm_build64 && make -C ${LLVM_CHECKOUT}/projects/libcxx installheaders \
  HEADER_DIR=${PWD}/include) || echo @@@STEP_FAILURE@@@
fi

# Now build everything else.
(cd llvm_build64 && make -j$MAKE_JOBS) || echo @@@STEP_FAILURE@@@
FRESH_CLANG_PATH=${ROOT}/llvm_build64/bin
COMPILER_RT_BUILD_PATH=projects/compiler-rt/src/compiler-rt-build

echo @@@BUILD_STEP run asan tests@@@
(cd llvm_build64 && make -j$MAKE_JOBS check-asan) || echo @@@STEP_FAILURE@@@

if [ "$PLATFORM" == "Linux" -a "$ARCH" == "x86_64" ]; then
  echo @@@BUILD_STEP run msan unit tests@@@
  (cd llvm_build64 && make -j$MAKE_JOBS check-msan) || echo @@@STEP_FAILURE@@@
fi

if [ "$PLATFORM" == "Linux" -a "$ARCH" == "x86_64" ]; then
  echo @@@BUILD_STEP run 64-bit tsan unit tests@@@
  (cd llvm_build64 && make -j$MAKE_JOBS check-tsan) || echo @@@STEP_FAILURE@@@
fi

if [ "$PLATFORM" == "Linux" -a "$ARCH" == "x86_64" ]; then
  echo @@@BUILD_STEP run 64-bit lsan unit tests@@@
  (cd llvm_build64 && make -j$MAKE_JOBS check-lsan) || echo @@@STEP_FAILURE@@@
fi

echo @@@BUILD_STEP run sanitizer_common tests@@@
(cd llvm_build64 && make -j$MAKE_JOBS check-sanitizer) || echo @@@STEP_FAILURE@@@

echo @@@BUILD_STEP build standalone compiler-rt@@@
if [ ! -d compiler_rt_build ]; then
  mkdir compiler_rt_build
fi
(cd compiler_rt_build && cmake -DCMAKE_BUILD_TYPE=$BUILD_TYPE \
  -DCMAKE_C_COMPILER=${FRESH_CLANG_PATH}/clang \
  -DCMAKE_CXX_COMPILER=${FRESH_CLANG_PATH}/clang++ \
  -DCOMPILER_RT_INCLUDE_TESTS=ON \
  -DCOMPILER_RT_ENABLE_WERROR=ON \
  -DLLVM_CONFIG_PATH=${FRESH_CLANG_PATH}/llvm-config \
  $COMPILER_RT_CHECKOUT)
(cd compiler_rt_build && make -j$MAKE_JOBS) || echo @@@STEP_FAILURE@@@

echo @@@BUILD_STEP test standalone compiler-rt@@@
(cd compiler_rt_build && make -j$MAKE_JOBS check-all) || echo @@@STEP_FAILURE@@@

HAVE_NINJA=${HAVE_NINJA:-1}
if [ "$PLATFORM" == "Linux" -a $HAVE_NINJA == 1 ]; then
  echo @@@BUILD_STEP run tests in ninja build tree@@@
  if [ ! -d llvm_build_ninja ]; then
    mkdir llvm_build_ninja
  fi
  CMAKE_NINJA_OPTIONS="${CMAKE_CLANG_OPTIONS} -DCMAKE_EXPORT_COMPILE_COMMANDS=ON -G Ninja"
  (cd llvm_build_ninja && cmake -DCMAKE_BUILD_TYPE=$BUILD_TYPE \
      ${CMAKE_NINJA_OPTIONS} $LLVM_CHECKOUT)
  ln -sf llvm_build_ninja/compile_commands.json $LLVM_CHECKOUT
  (cd llvm_build_ninja && ninja check-asan) || echo @@@STEP_FAILURE@@@
  (cd llvm_build_ninja && ninja check-sanitizer) || echo @@@STEP_FAILURE@@@
  (cd llvm_build_ninja && ninja check-tsan) || echo @@@STEP_FAILURE@@@
  (cd llvm_build_ninja && ninja check-msan) || echo @@@STEP_FAILURE@@@
  (cd llvm_build_ninja && ninja check-lsan) || echo @@@STEP_FAILURE@@@
  (cd llvm_build_ninja && ninja check-ubsan) || echo @@@STEP_WARNINGS@@@
  (cd llvm_build_ninja && ninja check-dfsan) || echo @@@STEP_WARNINGS@@@
fi

BUILD_ANDROID=${BUILD_ANDROID:-0}
if [ $BUILD_ANDROID == 1 ] ; then
    echo @@@BUILD_STEP build Android runtime and tests@@@
    ANDROID_TOOLCHAIN=$ROOT/../../../android-ndk/standalone
    ANDROID_BUILD_DIR=compiler_rt_build_android

    # Always clobber android build tree.
    # It has a hidden dependency on clang (through CXX) which is not known to
    # the build system.
    rm -rf $ANDROID_BUILD_DIR
    mkdir $ANDROID_BUILD_DIR
    ANDROID_FLAGS="--target=arm-linux-androideabi --sysroot=$ANDROID_TOOLCHAIN/sysroot -B$ANDROID_TOOLCHAIN"
    (cd $ANDROID_BUILD_DIR && \
        cmake -GNinja -DCMAKE_BUILD_TYPE=$BUILD_TYPE \
        -DCMAKE_C_COMPILER=$ROOT/llvm_build64/bin/clang \
        -DCMAKE_CXX_COMPILER=$ROOT/llvm_build64/bin/clang++ \
        -DLLVM_CONFIG_PATH=$ROOT/llvm_build64/bin/llvm-config \
        -DCOMPILER_RT_INCLUDE_TESTS=ON \
        -DCOMPILER_RT_ENABLE_WERROR=ON \
        -DCMAKE_C_FLAGS="$ANDROID_FLAGS" \
        -DCMAKE_CXX_FLAGS="$ANDROID_FLAGS" \
        -DANDROID=1 \
        -DCOMPILER_RT_TEST_TARGET_TRIPLE=arm-linux-androideabi \
        -DCOMPILER_RT_TEST_COMPILER_CFLAGS="$ANDROID_FLAGS" \
        ${CMAKE_COMMON_OPTIONS} \
        $LLVM_CHECKOUT/projects/compiler-rt)
    (cd $ANDROID_BUILD_DIR && ninja AsanUnitTests SanitizerUnitTests) || \
        echo @@@STEP_FAILURE@@@
fi

RUN_ANDROID=${RUN_ANDROID:-0}
if [ $RUN_ANDROID == 1 ] ; then
    echo @@@BUILD_STEP device setup@@@
    ADB=$ROOT/../../../android-sdk-linux/platform-tools/adb
    DEVICE_ROOT=/data/local/asan_test

    echo "Rebooting the device"
    $ADB reboot
    $ADB wait-for-device
    sleep 5

    $ADB devices

    ASAN_RT_LIB=libclang_rt.asan-arm-android.so
    ASAN_RT_LIB_PATH=`find $ANDROID_BUILD_DIR/lib -name $ASAN_RT_LIB`
    echo "ASan runtime: $ASAN_RT_LIB_PATH"
    ADB=$ADB $LLVM_CHECKOUT/projects/compiler-rt/lib/asan/scripts/asan_device_setup \
        --lib $ASAN_RT_LIB_PATH
    sleep 2

    $ADB shell rm -rf $DEVICE_ROOT
    $ADB shell mkdir $DEVICE_ROOT

    # Copy asan-rt into toolchain build dir.
    # Eventually this should be done in the build system.
    ASAN_RT_INSTALL_DIR=$(ls -d llvm_build64/lib/clang/*/lib/linux/ | tail -1)
    cp $ASAN_RT_LIB_PATH $ASAN_RT_INSTALL_DIR

    echo @@@BUILD_STEP run asan lit tests [Android]@@@

    (cd $ANDROID_BUILD_DIR && ninja check-asan) || \
        echo @@@STEP_FAILURE@@@

    echo @@@BUILD_STEP run sanitizer_common tests [Android]@@@

    $ADB push $ANDROID_BUILD_DIR/lib/sanitizer_common/tests/SanitizerTest $DEVICE_ROOT/

    $ADB shell "$DEVICE_ROOT/SanitizerTest; \
        echo \$? >$DEVICE_ROOT/error_code"
    $ADB pull $DEVICE_ROOT/error_code error_code && (exit `cat error_code`) || echo @@@STEP_FAILURE@@@

    echo @@@BUILD_STEP run asan tests [Android]@@@

    $ADB push $ANDROID_BUILD_DIR/lib/asan/tests/AsanTest $DEVICE_ROOT/
    $ADB push $ANDROID_BUILD_DIR/lib/asan/tests/AsanNoinstTest $DEVICE_ROOT/

    NUM_SHARDS=7
    for ((SHARD=0; SHARD < $NUM_SHARDS; SHARD++)); do
        $ADB shell "ASAN_OPTIONS=start_deactivated=1 \
          GTEST_TOTAL_SHARDS=$NUM_SHARDS \
          GTEST_SHARD_INDEX=$SHARD \
          asanwrapper $DEVICE_ROOT/AsanTest; \
          echo \$? >$DEVICE_ROOT/error_code"
        $ADB pull $DEVICE_ROOT/error_code error_code && echo && (exit `cat error_code`) || echo @@@STEP_FAILURE@@@
        $ADB shell " \
          GTEST_TOTAL_SHARDS=$NUM_SHARDS \
          GTEST_SHARD_INDEX=$SHARD \
          $DEVICE_ROOT/AsanNoinstTest; \
          echo \$? >$DEVICE_ROOT/error_code"
        $ADB pull $DEVICE_ROOT/error_code error_code && echo && (exit `cat error_code`) || echo @@@STEP_FAILURE@@@
    done
fi
