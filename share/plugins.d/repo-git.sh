declare -x GIT_URL

plugin_on_load_config_pre_repo_git() {
  GIT_URL=""
}

plugin_repo_update_git() {
  if [[ ! -d .git ]]; then
    if [[ -z "$GIT_URL" ]]; then
      error "GIT_URL not defined"
    fi

    log "Starting clone of $GIT_URL"
    if ! git clone $GIT_URL .; then
      error "git clone returned $?"
    fi
    log "Clone finished without error"
    exit 0
  fi

  local cur_url=$(git ls-remote --get-url)
  log "Starting update of $cur_url"

  local old_local=$(git rev-parse @{0})

  if ! git pull; then
    error "git pull returned $?"
  fi

  local new_local=$(git rev-parse @{0})
  echo ""
  if [[ "$old_local" = "$new_local" ]]; then
    log "Last commit $(echo $old_local | cut -b 1-7):"
    git log -1 || true
  else
    log "Commits between $(echo $old_local | cut -b 1-7) and $(echo $new_local | cut -b 1-7):"
    git log $old_local..$new_local || true
  fi

  log "Update finished successfully"
  exit 0
}

plugin_repo_poll_git() {
  if [[ ! -d .git ]]; then
    log "No .git directory, considering out of date"
    exit 2
  fi

  if ! git remote update; then
    error "git remote update returned $?"
  fi

  local local=$(git rev-parse @{0})
  local remote=$(git rev-parse @{u})
  local base=$(git merge-base @{0} @{u})

  echo "Local: $local"
  echo "Remote: $remote"
  echo "Base: $base"

  if [ "$local" = "$remote" ]; then
    log "Repository up to date"
    exit 0
  elif [ "$local" = "$base" ]; then
    echo "Repository out of date"
    exit 2
  elif [ "$remote" = "$base" ]; then
    error "Local commits in repository"
  else
    error "Repositories have diverged"
  fi
}

# Local Variables:
# sh-basic-offset: 2
# sh-indentation: 2
# indent-tabs-mode: nil
# End:
