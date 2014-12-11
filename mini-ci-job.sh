#!/bin/bash

set -e

# TODO: Should be set before running
export _MINICI_LIBDIR="$(pwd)"
export _MINICI_MASTER=$PPID
export _MINICI_DEBUG=yes
export _MINICI_JOB_NAME=test-job
export _MINICI_JOB_DIR="$(pwd)/test-dir/jobs/$_MINICI_JOB_NAME"
export _MINICI_JOB_WORKSPACE="$_MINICI_JOB_DIR/workspace"
export _MINICI_JOB_CONFIG="${_MINICI_JOB_DIR}/config"

_MINICI_JOB_POLL_LOG="${_MINICI_JOB_DIR}/poll.log"
_MINICI_JOB_UPDATE_LOG="${_MINICI_JOB_DIR}/update.log"
_MINICI_JOB_BUILD_LOG="${_MINICI_JOB_DIR}/build.log"

_MINICI_JOB_STATUS_POLL="UNKNOWN"
_MINICI_JOB_STATUS_UPDATE="UNKNOWN"
_MINICI_JOB_STATUS_BUILD="UNKNOWN"

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

if [[ -z "$_MINICI_JOB_CONFIG" ]]; then
    error "Unable to determine job configuration file"
fi

_MINICI_JOB_CHILD_PIDS=()
_MINICI_JOB_CHILD_CBS=()

_minici_job_handle_children() {
    local tmpPids=()
    local tmpCBs=()
    for ((i=0; i < ${#_MINICI_JOB_CHILD_PIDS[@]}; ++i)); do
        local pid=${_MINICI_JOB_CHILD_PIDS[$i]}
        local cb=${_MINICI_JOB_CHILD_CBS[$i]}

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

    _MINICI_JOB_CHILD_PIDS=(${tmpPids[@]})
    _MINICI_JOB_CHILD_CBS=(${tmpCBs[@]})
}

_minici_job_queue() {
    debug "Queued $@"
    _MINICI_JOB_QUEUE=(${_MINICI_JOB_QUEUE[@]} $@)
}

_minici_job_child() {
    debug "Added child $@"
    _MINICI_JOB_CHILD_PIDS=(${_MINICI_JOB_CHILD_PIDS[@]} $1)
    _MINICI_JOB_CHILD_CBS=(${_MINICI_JOB_CHILD_CBS[@]} $2)
}

_minici_job_clean() {
    log "Cleaning workspace"
    if [[ -e "$_MINICI_JOB_WORKSPACE" ]]; then
        log "Removing workspace $_MINICI_JOB_WORKSPACE"
        rm -rf $_MINICI_JOB_WORKSPACE
    fi
    mkdir $_MINICI_JOB_WORKSPACE

    _minici_job_queue "update"
}

_minici_job_poll_start() {
    _MINICI_JOB_STATE="poll"
    log "Polling job"

    $REPO_HANDLER poll "$_MINICI_JOB_WORKSPACE" $REPO_URL > $_MINICI_JOB_POLL_LOG 2>&1 &
    _minici_job_child $! "_minici_job_poll_finish"
}

_minici_job_poll_finish() {
    _MINICI_JOB_STATE="idle"
    line=$(tail -n 1 $_MINICI_JOB_POLL_LOG)
    if [[ $1 -eq 0 ]]; then
        _MINICI_JOB_STATUS_POLL="OK"
        if [[ "$line" = "OK POLL NEEDED" ]]; then
            log "Poll finished sucessfully, queuing update"
            _minici_job_queue "update"
        else
            log "Poll finished sucessfully, no update required"
        fi
    else
        _MINICI_JOB_STATUS_POLL="ERROR"
        warning "Update did not finish sucessfully: $line"
    fi
}

_minici_job_update_start() {
    _MINICI_JOB_STATE="update"
    log "Updating workspace"

    $REPO_HANDLER update "$_MINICI_JOB_WORKSPACE" $REPO_URL > $_MINICI_JOB_UPDATE_LOG 2>&1 &
    _minici_job_child $! "_minici_job_update_finish"
}

_minici_job_update_finish() {
    _MINICI_JOB_STATE="idle"
    if [[ $1 -eq 0 ]]; then
        _MINICI_JOB_STATUS_UPDATE="OK"
        log "Update finished sucessfully, queuing build"
        _minici_job_queue "build"
    else
        _MINICI_JOB_STATUS_UPDATE="ERROR"
        warning "Update did not finish sucessfully"
    fi
}

_minici_job_build_start() {
    _MINICI_JOB_STATE="build"
    log "Starting build"
    _MINICI_JOB_STATE="idle"
    _MINICI_JOB_STATUS_BUILD="OK"
}

_minici_job_abort() {
    unset _MINICI_JOB_QUEUE

    OK="ERR"

    case $_MINICI_JOB_STATE in
        idle)
            OK="OK"
            ;;

        poll|update|build)
            OK="OK"
            ;;

        *)
            warning "Job in unknown busy state: $_MINICI_JOB_BUSY"
            ;;
    esac

    if [[ "$OK" = "OK" ]]; then
        _MINICI_JOB_STATE="idle"
    fi
    echo "$OK ABORT $STATE"
}

_minici_job_status() {
    echo "OK PID:$$ STATE:$_MINICI_JOB_STATE QUEUE:[${_MINICI_JOB_QUEUE[@]}] POLL:$_MINICI_JOB_STATUS_POLL UPDATE:$_MINICI_JOB_STATUS_UPDATE BUILD:$_MINICI_JOB_STATUS_BUILD"
}

_minici_job_shutdown() {
    log "Shutting down"
}

_minici_job_read_commands() {
    while read -t 1 CMD ARGS; do
        #read CMD ARGS
        if [[ "$CMD" ]]; then
            CMD=$(echo $CMD | tr '[:upper:]' '[:lower:]')

            case $CMD in
                poll|update)
                    if [[ -x "$REPO_HANDLER" ]]; then
                        _minici_job_queue "$CMD"
                        echo "OK QUEUED"
                    else
                        debug "Repo handler not supported: $REPO_HANDLER"
                        echo "ERR UNSUPPORTED"
                    fi
                    ;;
                clean|build)
                    _minici_job_queue "$CMD"
                    echo "OK QUEUED"
                    ;;
                status)
                    _minici_job_status
                    ;;
                abort)
                    _minici_job_abort
                    ;;
                quit|shutdown)
                    _MINICI_JOB_RUN=no
                    _minici_job_abort
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

_minici_job_process_queue() {
    while [[ ${_MINICI_JOB_QUEUE[0]} ]]; do
        if [[ "$_MINICI_JOB_STATE" != "idle" ]]; then
            break
        fi

        CMD=${_MINICI_JOB_QUEUE[0]}
        _MINICI_JOB_QUEUE=(${_MINICI_JOB_QUEUE[@]:1})
        case $CMD in
            clean)
                _minici_job_clean
                ;;

            poll)
                _minici_job_poll_start
                ;;
            update)
                _minici_job_update_start
                ;;
            build)
                _minici_job_build_start
                ;;
            *)
                error "Unknown job in queue: $CMD"
                ;;
        esac
    done
}

_minici_job_start() {
    log "Starting up"

    test -e $_MINICI_JOB_CONFIG && source $_MINICI_JOB_CONFIG

    _MINICI_JOB_RUN=yes
    _MINICI_JOB_STATE=idle

    while [[ "$_MINICI_JOB_RUN" = "yes" ]]; do
        _minici_job_read_commands
        _minici_job_process_queue
        _minici_job_handle_children
        #sleep 1
    done

    _minici_job_shutdown
}

_minici_job_start
