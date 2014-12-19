# Mini-CI is a small daemon to perform continuous integration (CI) for
# a single repository/project.
#
# AUTHOR: Andrew Phillips <theasp@gmail.com>
# LICENSE: GPLv2

if [[ "${BASH_VERSINFO[0]}" -lt 4 ]]; then
  echo "ERROR: You need at least version 4 of BASH" 1>&2
  exit 1
fi

set -e

# This is from here, but ported to BASH:
# https://code.google.com/p/shunit2/wiki/HOWTO_TestAbsolutePathFn#Fourth_Go
make_full_path() {
  #set -x
  local shlib_path_=$1
  local shlib_old
  local shlib_new

  # prepend current directory to relative paths
  if [[ ! "${shlib_path_}" =~ ^/ ]]; then
    shlib_path_="$(pwd)/${shlib_path_}"
  fi

  # clean up the path. if all seds supported true regular expressions, then
  # this is what it would be:
  shlib_old_=${shlib_path_}

  while true; do
    shlib_new_=$(echo "${shlib_old_}" | sed 's![^/]*/\.\.\/*!!g; s!/\.\/!/!g')
    test "${shlib_old_}" = "${shlib_new_}" && break
    shlib_old_=${shlib_new_}
  done
  #set +x
  echo "${shlib_new_}"
}

# http://stackoverflow.com/questions/392022/best-way-to-kill-all-child-processes
killtree() {
  local _pid=$1
  local _sig=${2:--TERM}
  kill -stop ${_pid} # needed to stop quickly forking parent from producing children between child killing and parent killing
  for _child in $(pgrep -P ${_pid}); do
    killtree ${_child} ${_sig}
  done
  kill -${_sig} ${_pid}
}

error() {
  log "ERROR: $@"
  exit 1
}

debug() {
  if [ "$DEBUG" = "yes" ]; then
    log "DEBUG: $@"
  fi
}

warning() {
  log "WARN: $@"
}

log() {
  local msg="$(date '+%F %T') $SHNAME/$BASHPID $@"
  echo $msg 1>&2
  if [[ $LOG_FILE ]]; then
    echo $msg >> $LOG_FILE
  fi
}

# Local Variables:
# sh-basic-offset: 2
# sh-indentation: 2
# indent-tabs-mode: nil
# End:
