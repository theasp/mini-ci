#!/bin/bash

SHNAME=$(basename $0)
TMPDIR=$(mktemp -u -d "/tmp/${SHNAME}-XXXXXX")

source ./share/functions.sh
source ./share/plugins.d/build-keep.sh

set +e

testSetDefaults() {
    BUILD_KEEP="error"
    plugin_on_load_config_pre_build_keep
    assertEquals "BUILD_KEEP has wrong value" "0" "$BUILD_KEEP"
}

testCleansDirs() {
    TMPDIR=$(mktemp -d "/tmp/${SHNAME}-XXXXXX")


    for i in $(seq 1 20); do
        mkdir $TMPDIR/$i
    done

    plugin_on_load_config_pre_build_keep

    BUILDS_DIR=$TMPDIR
    BUILD_KEEP=5
    BUILD_NUMBER=20

    plugin_on_tasks_finish_post_build_keep
    assertEquals "Function return value" "0" "$?"

    assertEquals "Wrong number of entries in directory" "$BUILD_KEEP" "$(ls -1 $TMPDIR | wc -l)"

    rm -r $TMPDIR
}

. /usr/bin/shunit2
