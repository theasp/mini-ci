#!/bin/bash
# Mini-CI is a small daemon to perform continuous integration (CI) for
# a single repository/project.
#
# AUTHOR: Andrew Phillips <theasp@gmail.com>
# LICENSE: GPLv2

if [[ -z "$MINI_CI_DIR" ]]; then
  echo "ERROR: MINI_CI_DIR not set.  Are you loading this under Mini-CI?" 1>&2
  exit 1
fi

source $MINI_CI_DIR/functions.sh

set -e

readonly SHNAME=$(basename $0)

# Clear all global variables.  This prevents a problem where their
# values leak when testing mini-ci inside of mini-ci.
declare -A CUR_STATUS=()
declare -A CUR_STATUS_TIME=()

declare -x BUILD_DISPLAY_NAME=""
declare -x BUILD_ID=""
declare -x BUILD_NUMBER=""
declare -x BUILD_OUTPUT_DIR=""
declare -x BUILD_TAG=""
declare -x JOB_DIR=""
declare -x JOB_NAME=""
declare -x WORKSPACE=""
declare BUILDS_DIR=""
declare CONFIG_FILE=""
declare CONTROL_FIFO=""
declare DEBUG=""
declare PID_FILE=""
declare POLL_DELAY=""
declare POLL_FREQ=""
declare POLL_LOG=""
declare REPO_PLUGIN=""
declare STATE=""
declare STATUS_FILE=""
declare TASKS_DIR=""
declare TASKS_LOG=""
declare UPDATE_LOG=""

help() {
  cat <<EOF
Usage: $SHNAME [option ...] [command ...]

Options:
  -d|--job-dir <dir>       directory for job
  -c|--config-file <file>  config file to use, relative to job-dir
  -m|--message [timeout]   send commands to running daemon, then exit
  -o|--oknodo              exit quietly if already running
  -D|--debug               log debugging information
  -F|--foreground          do not become a daemon, run in foreground
  -h|--help                show usage information and exit

Commands:
  status  log the current status
  poll    poll the source code repository for updates, queue update if
          updates are available
  update  update the source code repository, queue tasks if updates are made
  tasks   run the tasks in the tasks directory
  clean   remove the work directory
  abort   abort the currently running command
  quit|shutdown
          shutdown the daemon, aborting any running command
  reload  reread the config file, aborting any running command

Commands given while not in message mode will be queued.  For instance
the following command will have a repository polled for updates (which
will trigger update and tasks if required) then quit.
  $SHNAME -d <dir> -F poll quit
EOF
}


main() {
  local temp=$(getopt -o c:,d:,m::,o,D,F,h --long timeout:,config-file:,job-dir:,message::,oknodo,debug,foreground,help -n 'test.sh' -- "$@")
  eval set -- "$temp"

  local message=no
  local timeout=5
  local daemon=yes
  local oknodo=no
  DEBUG=no
  JOB_DIR="."
  CONFIG_FILE="./config"

  while true; do
    case "$1" in
      -c|--config-file)
        CONFIG_FILE=$2; shift 2 ;;
      -d|--job-dir)
        JOB_DIR=$2; shift 2 ;;
      -m|--message)
        message=yes
        if [[ -n "$2" ]]; then

          timeout=$2
        fi
        shift 2
        ;;
      -o|--oknodo)
        oknodo=yes; shift 1 ;;
      -D|--debug)
        DEBUG=yes; shift 1 ;;
      -F|--foreground)
        daemon=no; shift 1 ;;
      -h|--help)
        help
        exit 0
        ;;
      --)
        shift ; break  ;;
      *)
        echo "ERROR: Problem parsing arguments" 1>&2; exit 1 ;;
    esac
  done

  cd $JOB_DIR
  JOB_DIR=$(pwd)

  # Load the plugins.  Has to be done here
  for dir in "${MINI_CI_DIR}/plugins.d" "${JOB_DIR}/plugins.d"; do
    debug "Looking for plugins in $dir"
    if [[ -d "$dir" ]]; then
      for plugin in $(ls -1 $dir/*.sh); do
        debug "Loading plugin $plugin"
        source "$plugin"
      done
    fi
  done

  load_config

  if [[ "$message" = "yes" ]]; then
    unset LOG_FILE
    if [[ ! -e "$CONTROL_FIFO" ]]; then
      error "Control fifo $CONTROL_FIFO is missing"
    fi

    for cmd in $@; do
      send_message "$timeout" "$cmd"
    done
    exit 0
  fi

  acquire_lock $oknodo

  for cmd in $@; do
    queue "$cmd"
  done

  if [[ "$daemon" = "yes" ]]; then
    # Based on:
    # http://blog.n01se.net/blog-n01se-net-p-145.html
    [[ -t 0 ]] && exec </dev/null || true
    [[ -t 1 ]] && exec >/dev/null || true
    [[ -t 2 ]] && exec 2>/dev/null || true

    # Double fork will detach the process
    (main_loop &) &
  else
    main_loop
  fi
}

main_loop() {
  log "Starting up"

  read_status_file

  rm -f "$CONTROL_FIFO"
  mkfifo "$CONTROL_FIFO"

  exec 3<> "$CONTROL_FIFO"

  trap reload_config SIGHUP
  trap quit SIGINT
  trap quit SIGTERM
  trap "queue update" SIGUSR1
  trap "queue build" SIGUSR2

  # Even though this was done before, make a new lock as your PID
  # may have changed if running as a daemon.
  acquire_lock

  STATE=idle
  NEXT_POLL=0

  while true; do
    # read_commands has a 1 second timeout
    read_commands
    process_queue
    handle_children
    if [[ "$POLL_FREQ" -gt 0 ]] && [[ $(printf '%(%s)T\n' -1) -ge "$NEXT_POLL" ]] && [[ "$STATE" = "idle" ]]; then
      debug "Poll frequency timeout"
      queue "poll"
      schedule_poll
    fi
  done
}

queue() {
  do_hook "queue_pre" || return

  local cmd="$1"

  QUEUE=(${QUEUE[@]} "$@")
  debug "Queued $@"

  do_hook "queue_post" || return
}

add_child() {
  debug "Added child $@"
  CHILD_PIDS=(${CHILD_PIDS[@]} $1)
  CHILD_CBS=(${CHILD_CBS[@]} $2)
}

clean() {
  do_hook "clean_pre" || return

  log "Cleaning workspace"
  if [[ -e "$WORKSPACE" ]]; then
    log "Removing workspace $WORKSPACE"
    rm -rf $WORKSPACE
  fi
  queue "update"

  do_hook "clean_post" || return
}

schedule_poll() {
  do_hook "schedule_poll_pre" || return

  if [[ "$POLL_FREQ" -gt 0 ]]; then
    NEXT_POLL=$(( $(printf '%(%s)T\n' -1) + $POLL_FREQ))
  fi

  do_hook "schedule_poll_post" || return
}

run_repo() {
  local operation=$1
  local callback=$2
  local log_file=$3

  if [[ -n "$REPO_PLUGIN" ]]; then
    local f=$(find_plugin_function "repo_${operation}_${REPO_PLUGIN}")
    if [[ -n "$f" ]]; then
      (cd $WORKSPACE && LOG_FILE=/dev/stdout $f) < /dev/null > $log_file 2>&1 &
      add_child $! $callback
      return 0
    else
      warning "Unable to $operation, plugin $REPO_PLUGIN not found"
      return 1
    fi
  fi
  warning "No repo plugin defined"
  return 1
}

poll_start() {
  if [[ ! -e $WORKSPACE ]]; then
    (LOG_FILE=$POLL_LOG; log "Missing workdir, doing update instead")
    update_start
  else
    log "Polling job"
    do_hook "poll_start_pre" || return

    if run_repo poll "poll_finish" "$POLL_LOG"; then
      STATE="poll"
    else
      STATE="idle"
      update_status "poll" "ERROR"
    fi
  fi

  do_hook "poll_start_post" || return
}

poll_finish() {
  STATE="idle"

  do_hook "poll_finish_pre" || return

  if [[ "$1" -eq 0 ]]; then
    log "Poll finished sucessfully, no update required"
    update_status "poll" "OK"
  elif [[ "$1" -eq 2 ]]; then
    log "Poll finished sucessfully, queuing update"
    queue "update"
    update_status "poll" "OK"

    if [[ "$POLL_DELAY" -gt 0 ]]; then
      sleep "$POLL_DELAY"
    fi
  else
    warning "Poll did not finish sucessfully"
    update_status "poll" "ERROR"
  fi

  do_hook "poll_finish_post" || return
}

update_start() {
  log "Updating workspace"
  [[ -e "$WORKSPACE" ]] || mkdir "$WORKSPACE"
  do_hook "update_start_pre" || return

  if run_repo update "update_finish" "$UPDATE_LOG"; then
    STATE="update"
  else
    STATE="idle"
    update_status "update" "ERROR"
  fi

  do_hook "update_start_post" || return
}

update_finish() {
  STATE="idle"
  do_hook "update_finish_pre" || return

  if [[ "$1" -eq 0 ]]; then
    log "Update finished sucessfully, queuing tasks"
    update_status "update" "OK"
    # Set poll to ok too, because this did a poll too
    update_status "poll" "OK"
    queue "tasks"
  else
    warning "Update did not finish sucessfully"
    update_status "update" "ERROR"
  fi

  do_hook "update_finish_post" || return
}

tasks_start() {
  do_hook "tasks_start_pre" || return

  if [[ -d "$TASKS_DIR" ]]; then
    [[ -d "$BUILDS_DIR" ]] || mkdir "$BUILDS_DIR"

    BUILD_OUTPUT_DIR="$BUILDS_DIR"
    while [[ -d "$BUILD_OUTPUT_DIR" ]]; do
      BUILD_NUMBER=$(( $BUILD_NUMBER + 1 ))
      BUILD_OUTPUT_DIR="$BUILDS_DIR/$BUILD_NUMBER"
    done

    [[ -d "$BUILD_OUTPUT_DIR" ]] || mkdir "$BUILD_OUTPUT_DIR"

    [[ -f "$UPDATE_LOG" ]] && cp "$UPDATE_LOG" "$BUILD_OUTPUT_DIR/"

    BUILD_ID=$(date +%Y-%m-%d_%H-%M-%S)
    BUILD_DISPLAY_NAME="#${BUILD_NUMBER}"
    BUILD_TAG="${SHNAME}-${JOB_NAME}-${BUILD_NUMBER}"

    log "Starting tasks as build number $BUILD_NUMBER"
    run_tasks < /dev/null > $TASKS_LOG 2>&1 &
    add_child $! "tasks_finish"
    STATE="tasks"
  else
    warning "The tasks directory $TASKS_DIR does not exist"
    STATE="idle"
    update_status "tasks" "ERROR"
  fi

  do_hook "tasks_start_post" || return
}

tasks_finish() {
  STATE="idle"
  do_hook "tasks_finish_pre" || return

  if [[ "$1" -eq 0 ]]; then
    log "Tasks finished sucessfully, build number $BUILD_NUMBER"
    update_status "tasks" "OK"
  else
    warning "Tasks did not finish sucessfully, build number $BUILD_NUMBER"
    update_status "tasks" "ERROR"
  fi

  do_hook "tasks_finish_post" || return
}

abort() {
  log "Aborting any processes"
  do_hook "abort_pre" || return

  unset QUEUE

  local tmpPids=()
  local sleeptime=1
  for SIGNAL in TERM TERM KILL; do
    for ((i=0; i < ${#CHILD_PIDS[@]}; ++i)); do
      local pid=${CHILD_PIDS[$i]}

      if kill -0 $pid 2>/dev/null; then
        killtree $pid $SIGNAL
        debug "Killed child $pid with SIG$SIGNAL"
        tmpPids=(${tmpPids[@]} $pid)
      fi
    done
    if [[ ${#tmpPids} -gt 0 ]]; then
      sleep $sleeptime;
      sleeptime=5
    fi
  done

  if [[ ${#_tmpPids} -gt 0 ]]; then
    error "Processes remaining after abort: ${#CHILD_PIDS}"
  fi

  CHILD_PIDS=()
  CHILD_CBS=()

  case $STATE in
    poll|update|tasks) update_state $STATE "UNKNOWN" ;;
  esac

  STATE="idle"

  do_hook "abort_post" || return
}

write_status_file() {
  debug "Write status file $STATUS_FILE"
  do_hook "write_status_pre" || return

  local tmpfile=$STATUS_FILE.tmp
  local status_str=$(declare -p CUR_STATUS)
  local status_time_str=$(declare -p CUR_STATUS_TIME)

  cat > $tmpfile <<EOF
# Generated $(printf '%(%c)T\n' -1)
state=$STATE
build_number=$BUILD_NUMBER
status=${status_str#*=}
status_time=${status_time_str#*=}
EOF

  mv $tmpfile $STATUS_FILE

  do_hook "write_status_post" || return
}

read_status_file() {
  debug "Reading status file in $STATUS_FILE"

  do_hook "read_status_pre" || return

  for state in poll update tasks; do
    CUR_STATUS[$state]=UNKNOWN
    CUR_STATUS_TIME[$state]=""
  done

  if [[ -f "$STATUS_FILE" ]]; then
    local status
    local status_time
    local state
    local build_number

    source $STATUS_FILE

    eval "CUR_STATUS=${status}"
    eval "CUR_TIME=${status_time}"
    BUILD_NUMBER=$build_number

    if [[ "$state" ]] && [[ "$state" != "idle" ]]; then
      debug "Setting status of $state to UNKNOWN, previous active state"
      update_state $state "UNKNOWN"
    fi
  fi

  do_hook "read_status_post" || return
}

update_status() {
  local item=$1
  local new_status=$2
  local new_status_time=$(printf '%(%s)T\n' -1)

  do_hook "update_status_pre" || return

  debug "Setting status of $item to $new_status"

  local old_status=${CUR_STATUS["$item"]}
  local old_status_time=${CUR_STATUS["$item"]}

  CUR_STATUS["$item"]=$new_status
  CUR_STATUS_TIME["$item"]=$new_status_time

  write_status_file

  notify_status $item $old_status $old_status_time $new_status $new_status_time

  do_hook "update_status_post" || return
}

notify_status() {
  local item=$1
  local old=$2
  local old_time=$3
  local new=$4
  local new_time=$5

  do_hook "notify_status_pre" || return

  local -A notify_status

  case $new in
    OK)
      notify_status["OK"]=1
      if [[ "$old" = "ERROR" ]] || [[ "$old" = "UNKNOWN" ]]; then
        notify_status["RECOVER"]=1
      fi
      ;;
    ERROR|UNKNOWN)
      notify_status["$new"]=1
      if [[ "$old" = "OK" ]]; then
        notify_status["NEWPROB"]=1
      fi
      ;;
  esac

  local active_states
  for i in ${!notify_status[@]}; do
    if [[ "${notify_status[$i]}" -eq 1 ]]; then
      active_states="$i ";
    fi
  done

  for f in $(find_plugin_functions "notify"); do
    debug "Running notify plugin $f"
    # Run in subshell to prevent side effects
    $f $item $old $old_time $new $new_time "$active_states"
  done

  do_hook "notify_status_post" || return
}

run_tasks() {
  do_hook "run_tasks_pre" || return

  for task in $(ls -1 "$TASKS_DIR" | grep -E -e '^[a-zA-Z0-9_-]+$' | sort); do
    local file="$TASKS_DIR/$task"
    if [[ -x "$file" ]]; then
      local log_file="${BUILD_OUTPUT_DIR}/task-${task}.log"
      log "Running task $task, logging to ${BUILD_OUTPUT_DIR}/task-${task}.log" 2> "$log_file"

      if (cd "$WORKSPACE" && "$file") >> "$log_file" 2>&1; then
        log "Task $task returned code $?" 2>> "$log_file"
      else
        error "Task $task returned code $?" 2>> "$log_file"
      fi
    fi
  done

  do_hook "run_tasks_post" || return
}

status() {
  do_hook "status_pre" || return

  log "PID:$$ State:$STATE Queue:[${QUEUE[@]}] Poll:${CUR_STATUS[poll]} Update:${CUR_STATUS[update]} Tasks:${CUR_STATUS[tasks]}"

  do_hook "status_post" || return
}

read_commands() {
  do_hook "read_commands_pre" || return
  local cmd=""

  # If there is something queued and state is idle, only attempt a
  # read if there is something to read.  This should clear the queue
  # faster.
  if [[ "$STATE" = "idle" && "${!QUEUE[@]}" != "" ]]; then
    debug "Short wait"
    if read -t 0 <&3; then
      read -t 1 cmd <&3 || true
    fi
  else
    read -t 1 cmd <&3 || true
  fi

  if [[ -n "$cmd" ]]; then
    cmd=$(echo $cmd | tr '[:upper:]' '[:lower:]')

    case $cmd in
      poll|update|clean|tasks) queue "$cmd" ;;
      *) run_cmd $cmd ;;
    esac
  fi

  do_hook "read_commands_post" || return
}

run_cmd() {
  local cmd=$1

  do_hook "run_cmd_pre" || return

  case $cmd in
    quit|shutdown) quit ;;
    status) status ;;
    abort) abort ;;
    reload) reload_config ;;
    clean) clean ;;
    poll) poll_start ;;
    update) update_start ;;
    tasks) tasks_start ;;
    *) warning "Unknown command $cmd" ;;
  esac

  do_hook "run_cmd_pre" || return
}

process_queue() {
  do_hook "process_queue_pre" || return

  while [[ -n "${QUEUE[0]}" ]]; do
    if [[ "$STATE" != "idle" ]]; then
      break
    fi

    local cmd=${QUEUE[0]}
    QUEUE=(${QUEUE[@]:1})
    run_cmd $cmd
  done

  do_hook "process_queue_post" || return
}

reload_config() {
  log "Reloading configuration"

  do_hook "reload_config_pre" || return

  load_config
  # Abort needs to be after reading the config file so that the
  # status directory is valid.
  abort

  acquire_lock

  do_hook "reload_config_post" || return
}

load_config() {
  BUILDS_DIR="./builds"
  BUILD_KEEP=0
  CONTROL_FIFO="./control.fifo"
  LOG_FILE=""
  PID_FILE="./mini-ci.pid"
  POLL_DELAY=0
  POLL_FREQ=0
  POLL_LOG="./poll.log"
  REPO_PLUGIN=""
  REPO_URL=""
  STATUS_FILE="./status"
  TASKS_DIR="./tasks.d"
  TASKS_LOG="./tasks.log"
  UPDATE_LOG="./update.log"
  WORKSPACE="./workspace"

  do_hook "load_config_pre" || return

  if [[ -f "$CONFIG_FILE" ]]; then
    source $CONFIG_FILE
  else
    error "Unable to find configuration file $CONFIG_FILE"
  fi

  if [[ -z "$JOB_NAME" ]]; then
    JOB_NAME="$(basename $JOB_DIR)"
  fi

  if [[ -z "$LOG_FILE" ]]; then
    LOG_FILE="./mini-ci.log"
  fi

  cd "$JOB_DIR"
  BUILDS_DIR=$(make_full_path "$BUILDS_DIR")
  CONTROL_FIFO=$(make_full_path "$CONTROL_FIFO")
  LOG_FILE=$(make_full_path "$LOG_FILE")
  PID_FILE=$(make_full_path "$PID_FILE")
  POLL_LOG=$(make_full_path "$POLL_LOG")
  STATUS_FILE=$(make_full_path "$STATUS_FILE")
  TASKS_DIR=$(make_full_path "$TASKS_DIR")
  TASKS_LOG=$(make_full_path "$TASKS_LOG")
  UPDATE_LOG=$(make_full_path "$UPDATE_LOG")
  WORKSPACE=$(make_full_path "$WORKSPACE")

  do_hook "load_config_post" || return
}

acquire_lock() {
  local oknodo=$1

  do_hook "acquire_lock_pre" || return

  if [[ -e "$PID_FILE" ]]; then
    local test_pid="$(< $PID_FILE)"
    if [[ -n "$test_pid" ]] && [[ "$test_pid" -ne "$BASHPID" ]]; then
      debug "Lock file present $PID_FILE, has $test_pid"
      if kill -0 $test_pid >/dev/null 2>&1; then
        if [[ $oknodo = "yes" ]]; then
          debug "Unable to acquire lock.  Is $SHNAME running as PID ${TEST_PID}?"
          exit 0
        else
          error "Unable to acquire lock.  Is $SHNAME running as PID ${TEST_PID}?"
        fi
      fi
    fi
  fi

  debug "Writing $BASHPID to $PID_FILE"
  echo $BASHPID > "$PID_FILE"

  do_hook "acquire_lock_post" || return
}

send_message() {
  local timeout=$1
  local cmd=$2

  do_hook "send_message_pre" || return

  case $cmd in
    status|poll|update|tasks|clean|abort|quit|shutdown|reload) ;;
    *) error "Unknown command $cmd" ;;
  esac

  if [[ ! -p "$CONTROL_FIFO" ]]; then
    error "$CONTROL_FIFO is not a FIFO"
  fi

  local end_time=$(( $(printf '%(%s)T\n' -1) + $timeout ))
  (echo $cmd > $CONTROL_FIFO) &
  local echo_pid=$!

  while [[ $(printf '%(%s)T\n' -1) -lt $end_time ]]; do
    if ! kill -0 $echo_pid >/dev/null 2>&1; then
      break
    fi
    sleep 1
  done

  if kill -0 $echo_pid >/dev/null 2>&1; then
    kill -KILL $echo_pid
    error "Timeout writing $cmd to $CONTROL_FIFO"
  fi

  wait $echo_pid
  if [[ $? -ne 0 ]]; then
    error "Error writing to $CONTROL_FIFO"
  fi

  do_hook "send_message_post" || return
}

quit() {
  log "Shutting down"

  do_hook "quit_pre" || return

  abort
  rm -f $PID_FILE
  rm -f $CONTROL_FILE

  do_hook "quit_post" || return

  exit 0
}

handle_children() {
  local tmpPids=()
  local tmpCBs=()
  for ((i=0; i < ${#CHILD_PIDS[@]}; ++i)); do
    local pid=${CHILD_PIDS[$i]}
    local cb=${CHILD_CBS[$i]}

    if ! kill -0 $pid 2>/dev/null; then
      set +e
      wait $pid
      local RC=$?
      set -e
      debug "Child $pid done $RC"
      if [[ "$cb" ]]; then
        $cb $RC
      fi
    else
      tmpPids=(${tmpPids[@]} $pid)
      tmpCBs=(${tmpCBs[@]} $cb)
    fi
  done

  CHILD_PIDS=(${tmpPids[@]})
  CHILD_CBS=(${tmpCBs[@]})
}

do_hook() {
  local hook_name=$1
  local rc=0

  for f in $(find_plugin_functions "on_${hook_name}"); do
    # Filter debugging for plugin functions because some hooks will
    # fill filesystems...
    case $hook_name in
      read_command_pre|read_command_post) ;;
      process_queue_pre|process_queue_post) ;;
      queue_pre|queue_post) ;;
      *) debug "Executing plugin function $f" ;;
    esac

    if ! $f; then
      rc=$?
    fi
  done

  return $rc
}

find_plugin_functions() {
  local test_re="(plugin_$1_[A-Za-z0-9_]+) \(\)"
  while read line; do
    if [[ "$line" =~ $test_re ]]; then
      echo ${BASH_REMATCH[1]}
    fi
  done < <(set)
}

find_plugin_function() {
  local test_re="(plugin_$1) \(\)"
  debug "Looking for function matching $test_re"
  while read line; do
    if [[ "$line" =~ $test_re ]]; then
      debug "Found function ${BASH_REMATCH[1]}"
      echo ${BASH_REMATCH[1]}
      return
    fi
  done < <(set)
}

main "$@"

# Local Variables:
# sh-basic-offset: 2
# sh-indentation: 2
# indent-tabs-mode: nil
# End:
