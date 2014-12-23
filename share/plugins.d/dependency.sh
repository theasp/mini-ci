declare BUILD_DEPENDENCY_LIST
declare BUILD_DEPENDENCY_TIMEOUT

plugin_on_load_config_pre_dependency() {
  BUILD_DEPENDENCY_LIST=""
  BUILD_DEPENDENCY_TIMEOUT="1200" # 20 minutes
}

_plugin_dependency_check_status() {
  local file=$1
  local status local status_time local state local build_number
  source $file
  local -A status_array=$status
  if [[ ! "$state" = "idle" ]] || [[ ! "${status_array[tasks]}" = "OK" ]]; then
    exit 1
  else
    exit 0
  fi
}

plugin_on_tasks_start_pre_dependency() {
  [[ -z "$BUILD_DEPENDENCY_LIST" ]] && return 0

  local wait_end=$(( $(printf '%(%s)T\n' -1) + $BUILD_DEPENDENCY_TIMEOUT ))
  local timeout=0

  while true; do
    if [[ "$BUILD_DEPENDENCY_TIMEOUT" -gt 0 ]] && [[ $(printf '%(%s)T\n' -1) -ge $wait_end ]]; then
      timeout=1
      break
    fi

    local ok=1
    for file in $BUILD_DEPENDENCY_LIST; do
      if [[ -f $file ]] && ! (_plugin_dependency_check_status $file); then
        ok=0
      fi
    done

    [[ "$ok" == "1" ]] && break
    sleep 1
  done

  [[ "$timeout" != "0" ]] && return 1
  return 0
}

# Local Variables:
# sh-basic-offset: 2
# sh-indentation: 2
# indent-tabs-mode: nil
# End:
