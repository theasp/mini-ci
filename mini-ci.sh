#!/bin/bash

set -e

#DEBUG=yes
JOB_DIR="."
CONFIG="${JOB_DIR}/config"

if [[ -z "$JOB_DIR" ]]; then
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
    if [ "$DEBUG" = "yes" ]; then
        log "DEBUG: $@"
    fi
}

warning() {
    log "WARN: $@"
}

log() {
    msg="$(date +%F-%T) $BASHPID $@"
    echo $msg 1>&2
    if [[ $MINICI_LOG ]]; then
        echo $msg >> $MINICI_LOG
    fi
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

repo_run() {
    local OPERATION=$1
    local CALLBACK=$2

    if [[ $REPO_URL ]]; then
        if [[ $REPO_HANDLER ]]; then
            case $REPO_HANDLER in
                git|svn) # These are built in
                    cmd="_$REPO_HANDLER"
                    ;;

                *)
                    if [[ -x $REPO_HANDLER ]]; then
                        cmd=$REPO_HANDLER
                    else
                        warning "Unable to $OPERATION on $REPO_URL, $REPO_HANDLER is not executable"
                        return 1
                    fi
                    ;;
            esac

            ($cmd $OPERATION "$WORK_DIR" $REPO_URL > $POLL_LOG 2>&1) &
            add_child $! $CALLBACK
            return 0
        else
            warning "Unable to $OPERATION on $REPO_URL, REPO_HANDLER not set"
            return 1
        fi
    else
        warning "No REPO_URL defined"
        return 1
    fi
}

repo_poll_start() {
    if [[ ! -e $WORK_DIR ]]; then
        repo_update_start
    else
        STATE="poll"
        log "Polling job"

        STATUS_POLL="WORKING"
        update_status_files

        if ! repo_run poll "repo_poll_finish"; then
            STATE="idle"
            STATUS_POLL="ERROR"
        fi
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
        warning "Poll did not finish sucessfully"
    fi
    update_status_files
}

repo_update_start() {
    STATE="update"
    log "Updating workspace"

    test -e $WORK_DIR || mkdir $WORK_DIR

    STATUS_UPDATE="WORKING"
    update_status_files

    if ! repo_run update "repo_update_finish"; then
        STATE="idle"
        STATUS_POLL="ERROR"
    fi
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

        (run_tasks) > $TASKS_LOG 2>&1 &
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

quit() {
    log "Shutting down"
    abort
    rm -f $PID_FILE
    exit 0
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
                reload)
                    reload_config
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

reload_config() {
    log "Reloading configuration"
    load_config
    # Abort needs to be after reading the config file so that the
    # status directory is valid.
    abort
}

load_config() {
    CONTROL_FIFO="control.fifo"
    PID_FILE="minici.pid"
    WORK_DIR="workspace"
    TASKS_DIR="tasks.d"
    STATUS_DIR="status"
    LOG_DIR="log"
    POLL_LOG="${LOG_DIR}/poll.log"
    UPDATE_LOG="${LOG_DIR}/update.log"
    TASKS_LOG="${LOG_DIR}/tasks.log"
    POLL_FREQ=0

    if [[ -f $CONFIG ]]; then
        source $CONFIG
    else
        error "Unable to find configuration file $CONFIG"
    fi

    # Set this after sourcing the config file to hide the error when
    # running in an empty dir.
    if [[ -z $MINICI_LOG ]]; then
        MINICI_LOG="${LOG_DIR}/mini-ci.log"
    fi

    if [[ ! -d $LOG_DIR ]]; then
        mkdir $LOG_DIR
    fi

    STATUS_POLL="UNKNOWN"
    STATUS_UPDATE="UNKNOWN"
    STATUS_TASKS="UNKNOWN"

    read_status_files

    export CONTROL_FIFO
    export WORK_DIR
    export TASKS_DIR
    export WORK_DIR
    export LOG_DIR
    export STATUS_DIR
    export POLL_LOG
    export UPDATE_LOG
    export TASKS_LOG
    export POLL_FREQ

    cd $JOB_DIR
    acquire_lock
}

acquire_lock() {
    CUR_PID=$BASHPID
    if [[ -e $PID_FILE ]]; then
        TEST_PID=$(< $PID_FILE)
        if [[ $TEST_PID && $TEST_PID -ne $CUR_PID ]]; then
            debug "Lock file present $PID_FILE, has $TEST_PID"
            if kill -0 $TEST_PID >/dev/null 2>&1; then
                error "Unable to acquire lock.  Is minici running as PID ${TEST_PID}?"
            fi
        fi
    fi

    debug "Writing $CUR_PID to $PID_FILE"
    echo $CUR_PID > $PID_FILE
}

schedule_poll() {
    if [[ $POLL_FREQ ]] && [[ $POLL_FREQ -gt 0 ]]; then
        NEXT_POLL=$(( $(printf '%(%s)T\n' -1) + $POLL_FREQ))
    fi
}

main_loop() {
    log "Starting up"

    rm -f $CONTROL_FIFO
    mkfifo $CONTROL_FIFO

    exec 3<> $CONTROL_FIFO

    trap reload_config SIGHUP
    trap quit SIGINT
    trap quit SIGTERM
    trap "queue update" SIGUSR1
    trap "queue build" SIGUSR2

    # Even though this was done before, make a new lock as your PID
    # may have changed if running as a daemon.
    acquire_lock

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
            schedule_poll
        fi
    done

    quit
}

_git() {
    local OPERATION=$1
    local DIR=$2
    local REPO=$3

    if [ -z "$OPERATION" ]; then
        error "Missing argument OPERATION"
    fi

    if [ -z "$DIR" ]; then
        error "Missing argument DIR"
    fi

    if [ -z "$REPO" ]; then
        error "Missing argument REPO"
    fi

    cd $DIR

    case $OPERATION in
        update)
            if [ ! -d .git ]; then
                if ! git clone $REPO .; then
                    echo "ERR UPDATE CLONE"
                    exit 1
                fi
            else
                if ! git pull --rebase; then
                    echo "ERR UPDATE PULL"
                    exit 1
                fi
            fi
            echo "OK UPDATE"
            exit 0
            ;;

        poll)
            if ! git remote update; then
                echo "ERR POLL UPDATE"
                exit 1
            fi

            local LOCAL=$(git rev-parse @)
            local REMOTE=$(git rev-parse @{u})
            local BASE=$(git merge-base @ @{u})

            echo "Local: $LOCAL"
            echo "Remote: $REMOTE"
            echo "Base: $BASE"

            if [ $LOCAL = $REMOTE ]; then
                echo "OK POLL CURRENT"
                exit 0
            elif [ $LOCAL = $BASE ]; then
                echo "OK POLL NEEDED"
                exit 0
            elif [ $REMOTE = $BASE ]; then
                echo "ERR POLL LOCALCOMMITS"
                exit 1
            else
                echo "ERR POLL DIVERGED"
                exit 1
            fi
            ;;
        *)
            error "Unknown operation $OPERATION"
            ;;
    esac
}

_svn() {
    local OPERATION=$1
    local DIR=$2
    local REPO=$3

    if [ -z "$OPERATION" ]; then
        error "Missing argument OPERATION"
    fi

    if [ -z "$DIR" ]; then
        error "Missing argument DIR"
    fi

    if [ -z "$REPO" ]; then
        error "Missing argument REPO"
    fi

    cd $DIR

    case $OPERATION in
        update)
            if [ ! -d .svn ]; then
                if ! svn checkout $REPO .; then
                    echo "ERR UPDATE CHECKOUT"
                    exit 1
                fi
            else
                if ! svn update; then
                    echo "ERR UPDATE UPDATE"
                    exit 1
                fi
            fi
            echo "OK UPDATE"
            exit 0
            ;;

        poll)
            local LOCAL=$(svn info | grep '^Last Changed Rev' | cut -f 2 -d :)
            local REMOTE=$(svn info -r HEAD| grep '^Last Changed Rev' | cut -f 2 -d :)

            echo "Local: $LOCAL"
            echo "Remote: $REMOTE"

            if [[ $LOCAL -eq $REMOTE ]]; then
                echo "OK POLL CURRENT"
                exit 0
            else
                echo "OK POLL NEEDED"
                exit 0
            fi
            ;;
        *)
            error "Unknown operation $OPERATION"
            ;;
    esac
}

start() {
    load_config

    if [[ $DAEMON = "yes" ]]; then
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

start
