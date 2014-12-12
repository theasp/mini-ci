#!/bin/bash

set -e

# TODO: Should be set before running
export MINICI_LIBDIR="$(pwd)"
export MINICI_MASTER=$PPID
export MINICI_DEBUG=yes
export MINICI_JOB_NAME=test-job
export MINICI_JOB_DIR="$(pwd)/test-dir/jobs/$MINICI_JOB_NAME"
export MINICI_LOG_DIR="${MINICI_JOB_DIR}/log/"
export MINICI_STATUS_DIR="${MINICI_JOB_DIR}/status/"

CONFIG="${MINICI_JOB_DIR}/config"

POLL_LOG="${MINICI_LOG_DIR}/poll.log"
UPDATE_LOG="${MINICI_LOG_DIR}/update.log"
TASKS_LOG="${MINICI_LOG_DIR}/tasks.log"

STATUS_POLL="UNKNOWN"
STATUS_UPDATE="UNKNOWN"
STATUS_TASKS="UNKNOWN"

if [[ -z "$MINICI_LIBDIR" ]]; then
    echo "ERROR: LIBDIR not set.  Not running inside of mini-ci?" 1>&2
    exit 1
fi

source $MINICI_LIBDIR/functions.sh

if [[ -z "$MINICI_MASTER" ]]; then
    error "Unable to determine PID of master process"
fi

if [[ -z "$MINICI_JOB_NAME" ]]; then
    error "Unable to determine job name"
fi
MINICI_LOG_CONTEXT="$MINICI_JOB_NAME/job($$)"

if [[ -z "$MINICI_JOB_DIR" ]]; then
    error "Unable to determine job directory"
fi

if [[ -z "$CONFIG" ]]; then
    error "Unable to determine job configuration file"
fi

CHILD_PIDS=()
CHILD_CBS=()

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
            $cb $RC
        else
            tmpPids=(${tmpPids[@]} $pid)
            tmpCBs=(${tmpCBs[@]} $cb)
        fi
    done

    CHILD_PIDS=(${tmpPids[@]})
    CHILD_CBS=(${tmpCBs[@]})
}

queue() {
    debug "Queued $@"
    QUEUE=(${QUEUE[@]} $@)
}

add_child() {
    debug "Added child $@"
    CHILD_PIDS=(${CHILD_PIDS[@]} $1)
    CHILD_CBS=(${CHILD_CBS[@]} $2)
}

clean() {
    log "Cleaning workspace"
    if [[ -e "$WORK_DIR" ]]; then
        log "Removing workspace $WORK_DIR"
        rm -rf $WORK_DIR
    fi
    queue "update"
}

repo_poll_start() {
    if [[ ! -e $WORK_DIR ]]; then
        repo_update_start
    else
        STATE="poll"
        log "Polling job"

        STATUS_POLL="WORKING"
        update_status_files

        $REPO_HANDLER poll "$WORK_DIR" $REPO_URL > $POLL_LOG 2>&1 &
        add_child $! "repo_poll_finish"
    fi
}

repo_poll_finish() {
    STATE="idle"
    line=$(tail -n 1 $POLL_LOG)
    if [[ $1 -eq 0 ]]; then
        STATUS_POLL="OK"
        if [[ "$line" = "OK POLL NEEDED" ]]; then
            log "Poll finished sucessfully, queuing update"
            STATUS_UPDATE=EXPIRED
            STATUS_TASKS=EXPIRED
            queue "update"
        else
            log "Poll finished sucessfully, no update required"
        fi
    else
        STATUS_POLL="ERROR"
        warning "Update did not finish sucessfully: $line"
    fi
    update_status_files
}

repo_update_start() {
    STATE="update"
    log "Updating workspace"

    test -e $WORK_DIR || mkdir $WORK_DIR

    STATUS_UPDATE="WORKING"
    update_status_files

    $REPO_HANDLER update "$WORK_DIR" $REPO_URL > $UPDATE_LOG 2>&1 &
    add_child $! "repo_update_finish"
}

repo_update_finish() {
    STATE="idle"
    if [[ $1 -eq 0 ]]; then
        STATUS_UPDATE="OK"
        STATUS_TASKS=EXPIRED
        log "Update finished sucessfully, queuing tasks"
        queue "tasks"
    else
        STATUS_UPDATE="ERROR"
        warning "Update did not finish sucessfully"
    fi
    update_status_files
}

tasks_start() {
    STATE="tasks"
    log "Starting tasks"
    STATE="idle"
    STATUS_TASKS="WORKING"
    update_status_files
}

tasks_finish() {
    STATE="idle"
    STATUS_TASKS="OK"
}

abort() {
    unset QUEUE

    OK="ERR"

    case $STATE in
        idle)
            OK="OK"
            ;;

        poll|update|tasks)
            local tmpPids=()
            local tmpCBs=()
            SLEEPTIME=1
            for SIGNAL in TERM TERM KILL; do
                for ((i=0; i < ${#CHILD_PIDS[@]}; ++i)); do
                    local pid=${CHILD_PIDS[$i]}
                    local cb=${CHILD_CBS[$i]}

                    if kill -0 $pid 2>/dev/null; then
                        kill -$SIGNAL $pid 2>/dev/null
                        debug "Killed child $pid with SIG$SIGNAL"
                        tmpPids=(${tmpPids[@]} $pid)
                        tmpCBs=(${tmpCBs[@]} $cb)
                    fi
                done
                if [[ ${#tmpPids} -gt 0 ]]; then
                    sleep $SLEEPTIME;
                    SLEEPTIME=5
                fi
            done

            if [[ ${#_tmpPids} -gt 0 ]]; then
                error "Processes remaining after abort: ${#CHILD_PIDS}"
            fi

            CHILD_PIDS=(${tmpPids[@]})
            CHILD_CBS=(${tmpCBs[@]})
            ;;

        *)
            warning "Job in unknown busy state: $_BUSY"
            ;;
    esac

    if [[ "$OK" = "OK" ]]; then
        STATE="idle"
    fi
}

update_status_files() {
    debug "Updating state files in $MINICI_STATUS_DIR"
    test -e $MINICI_STATUS_DIR || mkdir $MINICI_STATUS_DIR

    echo "STATUS_POLL=$STATUS_POLL" > $MINICI_STATUS_DIR/poll.tmp
    mv $MINICI_STATUS_DIR/poll.tmp $MINICI_STATUS_DIR/poll

    echo "STATUS_UPDATE=$STATUS_UPDATE" > $MINICI_STATUS_DIR/update.tmp
    mv $MINICI_STATUS_DIR/update.tmp $MINICI_STATUS_DIR/update

    echo "STATUS_TASKS=$STATUS_TASKS" > $MINICI_STATUS_DIR/tasks.tmp
    mv $MINICI_STATUS_DIR/tasks.tmp $MINICI_STATUS_DIR/tasks
}

read_status_files() {
    debug "Reading state files in $MINICI_STATUS_DIR"

    test -e $MINICI_STATUS_DIR || mkdir $MINICI_STATUS_DIR

    for name in poll update tasks; do
        test -e $MINICI_STATUS_DIR/$name && source $MINICI_STATUS_DIR/$name || true
    done

    if [[ "$STATUS_POLL" = "WORKING" ]]; then
        STATUS_POLL="UNKNOWN"
    fi

    if [[ "$STATUS_UPDATE" = "WORKING" ]]; then
        STATUS_UPDATE="UNKNOWN"
    fi

    if [[ "$STATUS_TASKS" = "WORKING" ]]; then
        STATUS_TASKS="UNKNOWN"
    fi
}

status() {
    update_status_files
    log "PID:$$ State:$STATE Queue:[${QUEUE[@]}] Poll:$STATUS_POLL Update:$STATUS_UPDATE Tasks:$STATUS_TASKS"
}

_shutdown() {
    log "Shutting down"
}

read_commands() {
    while read -t 1 CMD ARGS; do
        #read CMD ARGS
        if [[ "$CMD" ]]; then
            CMD=$(echo $CMD | tr '[:upper:]' '[:lower:]')

            case $CMD in
                poll|update|clean|tasks)
                    queue "$CMD"
                    ;;
                status)
                    status
                    ;;
                abort)
                    abort
                    ;;
                quit|shutdown)
                    _RUN=no
                    abort
                    break
                    ;;
                *)
                    warning "Unknown command $CMD"
                    ;;
            esac
        fi
    done
}

process_queue() {
    while [[ ${QUEUE[0]} ]]; do
        if [[ "$STATE" != "idle" ]]; then
            break
        fi

        CMD=${QUEUE[0]}
        QUEUE=(${QUEUE[@]:1})
        case $CMD in
            clean)
                clean
                ;;

            poll)
                repo_poll_start
                ;;

            update)
                repo_update_start
                ;;

            tasks)
                tasks_start
                ;;

            *)
                error "Unknown job in queue: $CMD"
                ;;
        esac
    done
}

start() {
    log "Starting up"

    # Defaults
    WORK_DIR="$MINICI_JOB_DIR/workspace"

    test -e $CONFIG && source $CONFIG

    read_status_files

    RUN=yes
    STATE=idle
    NEXT_POLL=0

    while [[ "$RUN" = "yes" ]]; do
        # read_commands has a 1 second timeout
        read_commands
        process_queue
        handle_children
        if [[ $POLL_FREQ -gt 0 ]] && [[ $(printf '%(%s)T\n' -1) -gt $NEXT_POLL ]] && [[ $STATE = "idle" ]]; then
            debug "Poll frequency timeout"
            queue "poll"
            NEXT_POLL=$(( $(printf '%(%s)T\n' -1) + $POLL_FREQ))
        fi
    done

    _shutdown
}

start
