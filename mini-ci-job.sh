#!/bin/bash

set -e

# TODO: Should be set before running
export _MINICI_LIBDIR="$(pwd)"
export _MINICI_MASTER=$PPID
export _MINICI_DEBUG=yes
export _MINICI_JOB_NAME=test-job
export _MINICI_JOB_DIR="$(pwd)/test-dir/jobs/$_MINICI_JOB_NAME"
export _CONFIG="${_MINICI_JOB_DIR}/config"

_POLL_LOG="${_MINICI_JOB_DIR}/poll.log"
_UPDATE_LOG="${_MINICI_JOB_DIR}/update.log"
_TASKS_LOG="${_MINICI_JOB_DIR}/tasks.log"

_STATUS_POLL="UNKNOWN"
_STATUS_UPDATE="UNKNOWN"
_STATUS_TASKS="UNKNOWN"

if [[ -z "$_MINICI_LIBDIR" ]]; then
    echo "ERROR: LIBDIR not set.  Not running inside of mini-ci?" 1>&2
    exit 1
fi

source $_MINICI_LIBDIR/functions.sh

if [[ -z "$_MINICI_MASTER" ]]; then
    error "Unable to determine PID of master process"
fi

if [[ -z "$_MINICI_JOB_NAME" ]]; then
    error "Unable to determine job name"
fi
_MINICI_LOG_CONTEXT="job($$)/$_MINICI_JOB_NAME"

if [[ -z "$_MINICI_JOB_DIR" ]]; then
    error "Unable to determine job directory"
fi

if [[ -z "$_CONFIG" ]]; then
    error "Unable to determine job configuration file"
fi

_CHILD_PIDS=()
_CHILD_CBS=()

_handle_children() {
    local tmpPids=()
    local tmpCBs=()
    for ((i=0; i < ${#_CHILD_PIDS[@]}; ++i)); do
        local pid=${_CHILD_PIDS[$i]}
        local cb=${_CHILD_CBS[$i]}

        if ! kill -0 $pid 2>/dev/null; then
            set +e
            wait $pid
            local RC=$?
            set -e
            debug "Child $pid done $RC"
            $cb $RC
        else
            tmpPids=(${tmpPids[@]} $pid)
            tmpCBs=(${tmpCBs[@]} $cb)
        fi
    done

    _CHILD_PIDS=(${tmpPids[@]})
    _CHILD_CBS=(${tmpCBs[@]})
}

_queue() {
    debug "Queued $@"
    _QUEUE=(${_QUEUE[@]} $@)
}

_child() {
    debug "Added child $@"
    _CHILD_PIDS=(${_CHILD_PIDS[@]} $1)
    _CHILD_CBS=(${_CHILD_CBS[@]} $2)
}

_clean() {
    log "Cleaning workspace"
    if [[ -e "$WORKSPACE" ]]; then
        log "Removing workspace $WORKSPACE"
        rm -rf $WORKSPACE
    fi
    mkdir $WORKSPACE

    _queue "update"
}

_poll_start() {
    _STATE="poll"
    log "Polling job"

    $REPO_HANDLER poll "$WORKSPACE" $REPO_URL > $_POLL_LOG 2>&1 &
    _child $! "_poll_finish"
}

_poll_finish() {
    _STATE="idle"
    line=$(tail -n 1 $_POLL_LOG)
    if [[ $1 -eq 0 ]]; then
        _STATUS_POLL="OK"
        if [[ "$line" = "OK POLL NEEDED" ]]; then
            log "Poll finished sucessfully, queuing update"
            _queue "update"
        else
            log "Poll finished sucessfully, no update required"
        fi
    else
        _STATUS_POLL="ERROR"
        warning "Update did not finish sucessfully: $line"
    fi
}

_update_start() {
    _STATE="update"
    log "Updating workspace"

    $REPO_HANDLER update "$WORKSPACE" $REPO_URL > $_UPDATE_LOG 2>&1 &
    _child $! "_update_finish"
}

_update_finish() {
    _STATE="idle"
    if [[ $1 -eq 0 ]]; then
        _STATUS_UPDATE="OK"
        log "Update finished sucessfully, queuing tasks"
        _queue "tasks"
    else
        _STATUS_UPDATE="ERROR"
        warning "Update did not finish sucessfully"
    fi
}

_tasks_start() {
    _STATE="tasks"
    log "Starting tasks"
    _STATE="idle"
    _STATUS_TASKS="OK"
}

_tasks_finish() {
    _STATE="idle"
    _STATUS_TASKS="OK"
}

_abort() {
    unset _QUEUE

    OK="ERR"

    case $_STATE in
        idle)
            OK="OK"
            ;;

        poll|update|tasks)
            local tmpPids=()
            local tmpCBs=()
            for SIGNAL in -9 -9 -1; do
                for ((i=0; i < ${#_CHILD_PIDS[@]}; ++i)); do
                    local pid=${_CHILD_PIDS[$i]}
                    local cb=${_CHILD_CBS[$i]}

                    if kill -0 $pid 2>/dev/null; then
                        kill -9 $pid 2>/dev/null
                        debug "Killed child $pid with signal 9"
                        tmpPids=(${tmpPids[@]} $pid)
                        tmpCBs=(${tmpCBs[@]} $cb)
                    fi
                done
                if [[ ${#tmpPids} -gt 0 ]]; then
                    sleep 1;
                fi
            done

            if [[ ${#_tmpPids} -gt 0 ]]; then
                error "Processes remaining after abort: ${#_CHILD_PIDS}"
            fi

            _CHILD_PIDS=(${tmpPids[@]})
            _CHILD_CBS=(${tmpCBs[@]})
            ;;

        *)
            warning "Job in unknown busy state: $_BUSY"
            ;;
    esac

    if [[ "$OK" = "OK" ]]; then
        _STATE="idle"
    fi
    echo "$OK ABORT $STATE"
}

_status() {
    echo "OK PID:$$ STATE:$_STATE QUEUE:[${_QUEUE[@]}] POLL:$_STATUS_POLL UPDATE:$_STATUS_UPDATE TASKS:$_STATUS_TASKS"
}

_shutdown() {
    log "Shutting down"
}

_read_commands() {
    while read -t 1 CMD ARGS; do
        #read CMD ARGS
        if [[ "$CMD" ]]; then
            CMD=$(echo $CMD | tr '[:upper:]' '[:lower:]')

            case $CMD in
                poll|update)
                    if [[ -x "$REPO_HANDLER" ]]; then
                        _queue "$CMD"
                        echo "OK QUEUED"
                    else
                        debug "Repo handler not supported: $REPO_HANDLER"
                        echo "ERR UNSUPPORTED"
                    fi
                    ;;
                clean|tasks)
                    _queue "$CMD"
                    echo "OK QUEUED"
                    ;;
                status)
                    _status
                    ;;
                abort)
                    _abort
                    ;;
                quit|shutdown)
                    _RUN=no
                    _abort
                    echo "OK QUIT"
                    break
                    ;;
                *)
                    warning "Unknown command $CMD"
                    echo "ERR UNKNOWN $CMD"
                    ;;
            esac
        fi
    done
}

_process_queue() {
    while [[ ${_QUEUE[0]} ]]; do
        if [[ "$_STATE" != "idle" ]]; then
            break
        fi

        CMD=${_QUEUE[0]}
        _QUEUE=(${_QUEUE[@]:1})
        case $CMD in
            clean)
                _clean
                ;;

            poll)
                _poll_start
                ;;

            update)
                _update_start
                ;;

            tasks)
                _tasks_start
                ;;

            *)
                error "Unknown job in queue: $CMD"
                ;;
        esac
    done
}

_start() {
    log "Starting up"

    # Defaults
    WORKSPACE="$_MINICI_JOB_DIR/workspace"

    test -e $_CONFIG && source $_CONFIG

    _RUN=yes
    _STATE=idle
    _NEXT_POLL=0

    while [[ "$_RUN" = "yes" ]]; do
        # _read_commands has a 1 second timeout
        _read_commands
        _process_queue
        _handle_children
        if [[ $POLL_FREQ -gt 0 ]] && [[ $(printf '%(%s)T\n' -1) -gt $_NEXT_POLL ]] && [[ $_STATE = "idle" ]]; then
            debug "Poll frequency timeout"
            _queue "poll"
            _NEXT_POLL=$(( $(printf '%(%s)T\n' -1) + $POLL_FREQ))
        fi
    done

    _shutdown
}

_start
