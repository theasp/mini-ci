declare BUILD_ARCHIVE_WORKSPACE

plugin_on_load_config_pre_archive_workspace() {
    BUILD_ARCHIVE_WORKSPACE="no"
}

plugin_on_tasks_finish_post_archive_workspace() {
    if [[ "$BUILD_ARCHIVE_WORKSPACE" = "yes" ]]; then
        log "Archiving workspace for build $BUILD_NUMBER"
        cp -a $WORKSPACE $BUILD_OUTPUT_DIR/workspace
    fi
}
