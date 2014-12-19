declare EXTERNAL_CMD
declare EXTERNAL_ARGS

plugin_repo_update_external() {
  if [[ -z "$EXTERNAL_CMD" ]]; then
    error "EXTERNAL_CMD not defined"
  fi

  if [[ ! -x "$EXTERNAL_CMD" ]]; then
    error "$EXTERNAL_CMD is not executable"
  fi

  exec $EXTERNAL_CMD update $EXTERNAL_ARGS
}

plugin_repo_poll_external() {
  if [[ -z "$EXTERNAL_CMD" ]]; then
    error "EXTERNAL_CMD not defined"
  fi

  if [[ ! -x "$EXTERNAL_CMD" ]]; then
    error "$EXTERNAL_CMD is not executable"
  fi

  exec $EXTERNAL_CMD update $EXTERNAL_ARGS
}

# Local Variables:
# sh-basic-offset: 2
# sh-indentation: 2
# indent-tabs-mode: nil
# End:

