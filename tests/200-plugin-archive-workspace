#!/bin/bash

SHNAME=$(basename $0)
TMPDIR=$(mktemp -u -d "/tmp/${SHNAME}-XXXXXX")

source ./share/functions.sh
source ./share/plugins.d/archive-workspace.sh

set +e

testSetDefaults() {
    BUILD_ARCHIVE_WORKSPACE="error"
    plugin_on_load_config_pre_archive_workspace
    assertEquals "BUILD_ARCHIVE_WORKSPACE has wrong value" "no" "$BUILD_ARCHIVE_WORKSPACE"
}

testCleansDirs() {
    TMPDIR=$(mktemp -d "/tmp/${SHNAME}-XXXXXX")
    plugin_on_load_config_pre_archive_workspace

    WORKSPACE=$TMPDIR/workspace
    BUILD_OUTPUT_DIR=$TMPDIR/output
    BUILD_ARCHIVE_WORKSPACE="yes"

    mkdir $WORKSPACE
    mkdir $BUILD_OUTPUT_DIR

    plugin_on_tasks_finish_post_archive_workspace
    assertEquals "Function return value" "0" "$?"

    assertTrue "Archived workspace missing" "[ -d $BUILD_OUTPUT_DIR/workspace ]"

    rm -r $TMPDIR
}

. /usr/bin/shunit2
