declare -x SVN_URL=""
declare SVN_CMD="svn"

plugin_on_load_config_pre_repo_svn() {
  SVN_URL=""
}

plugin_repo_update_svn() {
  if [ ! -d .svn ]; then
    if [[ -z "$SVN_URL" ]]; then
      error "SVN_URL not defined"
    fi

    log "Starting checkout of $SVN_URL"
    if ! $SVN_CMD checkout $SVN_URL . < /dev/null; then
      error "$SVN_CMD checkout returned $?"
    fi
    log "Checkout finished without error"
  fi

  local cur_url=$(svn info . 2> /dev/null | grep -i '^URL:' | cut -d ' ' -f 2)
  log "Starting update of $cur_url"

  local old_local=$(svn info | grep '^Last Changed Rev' | cut -f 2 -d :)

  if ! $SVN_CMD update; then
    error "$SVN_CMD update returned $?"
  fi

  local new_local=$(svn info | grep '^Last Changed Rev' | cut -f 2 -d :)
  if [[ "$old_local" = "$new_local" ]]; then
    log "Last commit $old_local:"
    $SVN_CMD log -r $old_local || true
  else
    log "Commits between $old_local and new_local:"
    $SVN_CMD -r $old_local:$new_local || true
  fi

  log "Update finished successfully"
}

plugin_repo_poll_svn() {
  if [[ ! -d .svn ]]; then
    log "No .svn directory, considering out of date"
    exit 2
  fi

  local local=$($SVN_CMD info | grep '^Last Changed Rev' | cut -f 2 -d :)
  local remote=$($SVN_CMD info -r HEAD| grep '^Last Changed Rev' | cut -f 2 -d :)

  echo "Local: $local"
  echo "Remote: $remote"

  if [[ "$local" -eq "$remote" ]]; then
    log "Repository up to date"
    exit 0
  else
    echo "Repository out of date"
    exit 2
  fi
}

# Local Variables:
# sh-basic-offset: 2
# sh-indentation: 2
# indent-tabs-mode: nil
# End:
