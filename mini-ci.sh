#!/bin/bash

set -e

MINICI_DEBUG=yes
MINICI_JOB_DIR="$(pwd)/test-dir/base-os-3.0-unstable/"

CONFIG="${MINICI_JOB_DIR}/config"

source $MINICI_LIBDIR/functions.sh

MINICI_LOG_CONTEXT="job($$)"

if [[ -z "$MINICI_JOB_DIR" ]]; then
    error "Unable to determine job directory"
fi

if [[ -z "$CONFIG" ]]; then
    error "Unable to determine job configuration file"
fi

error() {
    log "ERROR: $@"
    exit 1
}

debug() {
    if [ "$MINICI_DEBUG" = "yes" ]; then
        log "DEBUG: $@"
    fi
}

warning() {
    log "WARN: $@"
}

log() {
    if [ "$MINICI_LOG_CONTEXT" ]; then
        msg="$MINICI_LOG_CONTEXT $@"
    else
        msg="$@"
    fi
    echo "$(date +%F-%T)" $msg 1>&2
}

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

    if [[ -e $TASKS_DIR ]]; then
        STATUS_TASKS="WORKING"
        update_status_files

        (MINICI_LOG_CONTEXT="tasks(\$\$)"; run_tasks) > $TASKS_LOG 2>&1 &
        add_child $! "tasks_finish"

    else
        STATUS_TASKS="ERROR"
        update_status_files

        STATE="idle"
        warning "The tasks directory $TASKS_DIR does not exist"
    fi
}

tasks_finish() {
    STATE="idle"
    if [[ $1 -eq 0 ]]; then
        STATUS_TASKS="OK"
        log "Tasks finished sucessfully"
    else
        STATUS_UPDATE="ERROR"
        warning "Tasks did not finish sucessfully"
    fi
    update_status_files
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


abort() {
    unset QUEUE

    local tmpPids=()
    SLEEPTIME=1
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
            sleep $SLEEPTIME;
            SLEEPTIME=5
        fi
    done

    if [[ ${#_tmpPids} -gt 0 ]]; then
        error "Processes remaining after abort: ${#CHILD_PIDS}"
    fi

    CHILD_PIDS=()
    CHILD_CBS=()

    case $STATE in
        poll)
            STATUS_POLL="UNKNOWN"
            ;;

        update)
            STATUS_UPDATE="UNKNOWN"
            ;;

        tasks)
            STATUS_TASKS="UNKNOWN"
            ;;
    esac
    update_status_files

    STATE="idle"
}

update_status_files() {
    debug "Updating state files in $STATUS_DIR"
    test -e $STATUS_DIR || mkdir $STATUS_DIR

    echo "STATUS_POLL=$STATUS_POLL" > $STATUS_DIR/poll.tmp
    mv $STATUS_DIR/poll.tmp $STATUS_DIR/poll

    echo "STATUS_UPDATE=$STATUS_UPDATE" > $STATUS_DIR/update.tmp
    mv $STATUS_DIR/update.tmp $STATUS_DIR/update

    echo "STATUS_TASKS=$STATUS_TASKS" > $STATUS_DIR/tasks.tmp
    mv $STATUS_DIR/tasks.tmp $STATUS_DIR/tasks
}

read_status_files() {
    debug "Reading state files in $STATUS_DIR"

    test -e $STATUS_DIR || mkdir $STATUS_DIR

    for name in poll update tasks; do
        test -e $STATUS_DIR/$name && source $STATUS_DIR/$name || true
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

run_tasks() {
    log "Running tasks"

    if [[ ! -d $TASKS_DIR ]]; then
        error "Can't find tasks directory $TASKS_DIR"
    fi

    cd $WORK_DIR

    TASKS_RE='^[a-zA-Z0-9_-]+$'
    set -x
    for task in $(ls -1 $TASKS_DIR | grep -E -e "$TASKS_RE" | sort); do
        file="$TASKS_DIR/$task"
        if [[ -x $file ]]; then
            LOG="${LOG_DIR}/${task}.log"
            log "Running $task"
            if ! $file > $LOG 2>&1; then
                error "Bad return code $?"
            fi
        fi
    done
}

status() {
    update_status_files
    log "PID:$$ State:$STATE Queue:[${QUEUE[@]}] Poll:$STATUS_POLL Update:$STATUS_UPDATE Tasks:$STATUS_TASKS"
}

_shutdown() {
    log "Shutting down"
    abort
}

read_commands() {
    while read -t 1 CMD ARGS <&3; do
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
                    RUN=no
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
    CONTROL_FIFO="${MINICI_JOB_DIR}/control.fifo"
    WORK_DIR="$MINICI_JOB_DIR/workspace"
    TASKS_DIR="$MINICI_JOB_DIR/tasks.d"
    LOG_DIR="$MINICI_JOB_DIR/log"
    STATUS_DIR="$MINICI_JOB_DIR/log"
    POLL_LOG="${LOG_DIR}/poll.log"
    UPDATE_LOG="${LOG_DIR}/update.log"
    TASKS_LOG="${LOG_DIR}/tasks.log"

    rm -f $CONTROL_FIFO
    mkfifo $CONTROL_FIFO

    exec 3<> $CONTROL_FIFO
    
    if [[ ! -d $LOG_DIR ]]; then
        mkdir $LOG_DIR
    fi

    test -e $CONFIG && source $CONFIG

    STATUS_POLL="UNKNOWN"
    STATUS_UPDATE="UNKNOWN"
    STATUS_TASKS="UNKNOWN"

    read_status_files

    RUN=yes
    STATE=idle
    NEXT_POLL=0

    while [[ "$RUN" = "yes" ]]; do
        # read_commands has a 1 second timeout
        read_commands
        process_queue
        handle_children
        if [[ $POLL_FREQ -gt 0 ]] && [[ $(printf '%(%s)T\n' -1) -ge $NEXT_POLL ]] && [[ $STATE = "idle" ]]; then
            debug "Poll frequency timeout"
            queue "poll"
            NEXT_POLL=$(( $(printf '%(%s)T\n' -1) + $POLL_FREQ))
        fi
    done

    _shutdown
}

start
