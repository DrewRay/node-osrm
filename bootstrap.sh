#!/bin/bash

set -e

# we pin the mason version to avoid changes in mason breaking builds
MASON_VERSION="3e0cc5a"

if [[ `which pkg-config` ]]; then
    echo "Success: Found pkg-config";
else
    echo "echo you need pkg-config installed";
    exit 1;
fi;

if [[ `which node` ]]; then
    echo "Success: Found node";
else
    echo "echo you need node installed";
    exit 1;
fi;

function dep() {
    ./.mason/mason install $1 $2
    ./.mason/mason link $1 $2
}

# Set 'osrm_release' to a branch, tag, or gitsha in package.json
export OSRM_RELEASE=$(node -e "console.log(require('./package.json').osrm_release)")
export CXX=${CXX:-clang++}
export BUILD_TYPE=${BUILD_TYPE:-Release}
export TARGET_DIR=${TARGET_DIR:-$(pwd)/lib/binding}
export OSRM_REPO=${OSRM_REPO:-"https://github.com/Project-OSRM/osrm-backend.git"}
export OSRM_DIR=$(pwd)/deps/osrm-backend-${BUILD_TYPE}

echo
echo "*******************"
echo -e "OSRM_RELEASE set to:   \033[1m\033[36m ${OSRM_RELEASE}\033[0m"
echo -e "BUILD_TYPE set to:     \033[1m\033[36m ${BUILD_TYPE}\033[0m"
echo -e "CXX set to:            \033[1m\033[36m ${CXX}\033[0m"
echo "*******************"
echo
echo

function all_deps() {
    dep cmake 3.2.2 &
    dep lua 5.3.0 &
    dep luabind e414c57bcb687bb3091b7c55bbff6947f052e46b &
    dep boost 1.61.0 &
    dep boost_libsystem 1.61.0 &
    dep boost_libthread 1.61.0 &
    dep boost_libfilesystem 1.61.0 &
    dep boost_libprogram_options 1.61.0 &
    dep boost_libregex 1.61.0 &
    dep boost_libiostreams 1.61.0 &
    dep boost_libtest 1.61.0 &
    dep boost_libdate_time 1.61.0 &
    dep expat 2.1.0 &
    dep stxxl 1.4.1 &
    dep bzip2 1.0.6 &
    dep zlib system &
    dep tbb 43_20150316 &
    wait
}

function move_tools() {
    cp -r ${MASON_HOME}/bin/osrm-* "${TARGET_DIR}/"
}

function copy_tbb() {
    if [[ `uname -s` == 'Darwin' ]]; then
        cp ${MASON_HOME}/lib/libtbb.dylib ${TARGET_DIR}/
        cp ${MASON_HOME}/lib/libtbbmalloc.dylib ${TARGET_DIR}/
    else
        cp ${MASON_HOME}/lib/libtbb.so.2 ${TARGET_DIR}/
        cp ${MASON_HOME}/lib/libtbbmalloc.so.2 ${TARGET_DIR}/
        cp ${MASON_HOME}/lib/libtbbmalloc_proxy.so.2 ${TARGET_DIR}/
    fi
}

function localize() {
    mkdir -p ${TARGET_DIR}
    copy_tbb
    cp ${MASON_HOME}/bin/lua ${TARGET_DIR}
    move_tools
}

function build_osrm() {
    if [[ ! -d ${OSRM_DIR} ]]; then
        echo "Fresh clone."
        mkdir -p ${OSRM_DIR}
        git clone ${OSRM_REPO} ${OSRM_DIR}
        pushd ${OSRM_DIR}
    else
        echo "Already cloned, fetching."
        pushd ${OSRM_DIR}
        git fetch
    fi

    git checkout ${OSRM_RELEASE}
    OSRM_HASH=$(git rev-parse HEAD)

    echo
    echo "*******************"
    echo -e "Using osrm-backend   \033[1m\033[36m ${OSRM_HASH}\033[0m"
    echo "*******************"
    echo

    mkdir -p build
    pushd build
    # put mason installed ccache on PATH
    # then osrm-backend will pick it up automatically
    export CCACHE_VERSION="3.2.4"
    ${MASON_DIR}/mason install ccache ${CCACHE_VERSION}
    export PATH=$(${MASON_DIR}/mason prefix ccache ${CCACHE_VERSION})/bin:${PATH}
    CMAKE_EXTRA_ARGS=""
    if [[ ${AR:-false} != false ]]; then
        CMAKE_EXTRA_ARGS="${CMAKE_EXTRA_ARGS} -DCMAKE_AR=${AR}"
    fi
    if [[ ${RANLIB:-false} != false ]]; then
        CMAKE_EXTRA_ARGS="${CMAKE_EXTRA_ARGS} -DCMAKE_RANLIB=${RANLIB}"
    fi
    if [[ ${NM:-false} != false ]]; then
        CMAKE_EXTRA_ARGS="${CMAKE_EXTRA_ARGS} -DCMAKE_NM=${NM}"
    fi
    ${MASON_HOME}/bin/cmake ../ -DCMAKE_INSTALL_PREFIX=${MASON_HOME} \
      -DCMAKE_CXX_COMPILER="$CXX" \
      -DBoost_NO_SYSTEM_PATHS=ON \
      -DTBB_INSTALL_DIR=${MASON_HOME} \
      -DCMAKE_INCLUDE_PATH=${MASON_HOME}/include \
      -DCMAKE_LIBRARY_PATH=${MASON_HOME}/lib \
      -DCMAKE_BUILD_TYPE=${BUILD_TYPE} \
      -DCMAKE_EXE_LINKER_FLAGS="${LINK_FLAGS}" \
      -DBoost_USE_STATIC_LIBS=ON \
      ${CMAKE_EXTRA_ARGS}
    make -j${JOBS} VERBOSE=1 && make install
    ccache -s
    popd

    popd
}

function setup_mason() {
    if [[ ! -d ./.mason ]]; then
        git clone https://github.com/mapbox/mason.git ./.mason
        (cd ./.mason && git checkout ${MASON_VERSION})
    else
        echo "Updating to latest mason"
        (cd ./.mason && git fetch && git checkout ${MASON_VERSION})
    fi
    export MASON_DIR=$(pwd)/.mason
    export MASON_HOME=$(pwd)/mason_packages/.link
    export PATH=$(pwd)/.mason:$PATH
    export CXX=${CXX:-clang++}
    export CC=${CC:-clang}
}

function main() {
    setup_mason
    all_deps
    # fix install name of tbb
    if [[ `uname -s` == 'Darwin' ]]; then
        install_name_tool -id @loader_path/libtbb.dylib ${MASON_HOME}/lib/libtbb.dylib
        install_name_tool -id @loader_path/libtbb.dylib ${MASON_HOME}/lib/libtbbmalloc.dylib
    fi
    export PKG_CONFIG_PATH=${MASON_HOME}/lib/pkgconfig

    # environment variables to tell the compiler and linker
    # to prefer mason paths over other paths when finding
    # headers and libraries. This should allow the build to
    # work even when conflicting versions of dependencies
    # exist on global paths
    # stopgap until c++17 :) (http://www.open-std.org/JTC1/SC22/WG21/docs/papers/2014/n4214.pdf)
    export C_INCLUDE_PATH="${MASON_HOME}/include"
    export CPLUS_INCLUDE_PATH="${MASON_HOME}/include"
    export LIBRARY_PATH="${MASON_HOME}/lib"

    LINK_FLAGS=""
    if [[ $(uname -s) == 'Linux' ]]; then
        LINK_FLAGS="${LINK_FLAGS} "'-Wl,-z,origin -Wl,-rpath=\$ORIGIN'
        # ensure rpath is picked up by node-osrm build
        export LDFLAGS="${LINK_FLAGS} ${LDFLAGS}"
    fi

    build_osrm

    localize
}

main
set +e
