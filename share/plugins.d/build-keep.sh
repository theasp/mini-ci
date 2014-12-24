declare BUILD_KEEP

plugin_on_load_config_pre_build_keep() {
  BUILD_KEEP="0"
}

plugin_on_tasks_finish_post_build_keep() {
  if [[ "$BUILD_KEEP" -gt 0 ]]; then
    while read num; do
      [[ -d "$BUILDS_DIR/$num" ]] && rm -r "$BUILDS_DIR/$num"
    done < <(seq 1 $(( $BUILD_NUMBER - $BUILD_KEEP)))
  fi
}

# Local Variables:
# sh-basic-offset: 2
# sh-indentation: 2
# indent-tabs-mode: nil
# End:
