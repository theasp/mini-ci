#!/bin/bash

set -e

SHNAME=$(basename $0)

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
    msg="$(date '+%F %T') $SHNAME/$BASHPID $@"
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

queue() {
    local cmd=$1
    case $cmd in
        status|poll|update|tasks|clean|abort|quit|shutdown|reload)
        ;;
        *)
            error "Unknown command: $cmd"
            exit 1
            ;;
    esac

    QUEUE=(${QUEUE[@]} $@)
    debug "Queued $@"
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

        if ! repo_run poll "repo_poll_finish"; then
            STATE="idle"
            update_status "poll" "ERROR"
        fi
    fi
}

repo_poll_finish() {
    STATE="idle"
    line=$(tail -n 1 $POLL_LOG)
    if [[ $1 -eq 0 ]]; then
        if [[ "$line" = "OK POLL NEEDED" ]]; then
            log "Poll finished sucessfully, queuing update"
            #STATUS_UPDATE=EXPIRED
            #STATUS_TASKS=EXPIRED
            queue "update"
        else
            log "Poll finished sucessfully, no update required"
        fi
        update_status "poll" "OK"
    else
        warning "Poll did not finish sucessfully"
        update_status "poll" "ERROR"
    fi
}

repo_update_start() {
    STATE="update"
    log "Updating workspace"

    test -e $WORK_DIR || mkdir $WORK_DIR

    if ! repo_run update "repo_update_finish"; then
        STATE="idle"
        update_status "update" "ERROR"
    fi
}

repo_update_finish() {
    STATE="idle"
    if [[ $1 -eq 0 ]]; then
        #STATUS_TASKS=EXPIRED
        log "Update finished sucessfully, queuing tasks"
        update_status "update" "OK"
        queue "tasks"
    else
        update_status "update" "ERROR"
        warning "Update did not finish sucessfully"
    fi
}

tasks_start() {
    STATE="tasks"
    log "Starting tasks"

    if [[ -e $TASKS_DIR ]]; then
        (run_tasks) > $TASKS_LOG 2>&1 &
        add_child $! "tasks_finish"
    else
        STATE="idle"
        update_status "tasks" "ERROR"
        warning "The tasks directory $TASKS_DIR does not exist"
    fi
}

tasks_finish() {
    STATE="idle"
    if [[ $1 -eq 0 ]]; then
        update_status "tasks" "OK"
        log "Tasks finished sucessfully"
    else
        update_status "tasks" "ERROR"
        warning "Tasks did not finish sucessfully"
    fi
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
        poll|update|tasks)
            CUR_STATUS[$STATE]="UNKNOWN";;
    esac

    STATE="idle"
}

write_status_file() {
    debug "Write status file $STATUS_FILE"

    TMPFILE=$STATUS_FILE.tmp

    cat > $TMPFILE <<EOF
# Generated $(printf '%(%c)T\n' -1)
OLD_STATE=$STATE
EOF

    for state in ${!CUR_STATUS[@]}; do
        echo "CUR_STATUS[$state]=${CUR_STATUS[$state]}"
    done >> $TMPFILE
    mv $TMPFILE $STATUS_FILE
}

read_status_file() {
    debug "Reading status file in $STATUS_FILE"

    for state in poll update tasks; do
        CUR_STATUS[$state]=UNKNOWN
    done

    if [[ -f $STATUS_FILE ]]; then
        source $STATUS_FILE
    fi

    if [[ "$OLD_STATE" ]] && [[ "$OLD_STATE" != "idle" ]]; then
        debug "Setting status of $STATE to UNKNOWN, previous active state"
        CUR_STATUS[$STATE]=UNKNOWN
    fi
}

declare -A CUR_STATUS
declare -A CUR_STATUS_TIME

update_status() {
    local item=$1
    local NEW_STATUS=$2
    local NEW_STATUS_TIME=$(printf '%(%s)T\n' -1)

    debug "Setting status of $item to $NEW_STATUS"

    OLD_STATUS=${CUR_STATUS["$item"]}
    OLD_STATUS_TIME=${CUR_STATUS["$item"]}

    CUR_STATUS["$item"]=$NEW_STATUS
    CUR_STATUS_TIME["$item"]=$NEW_STATUS_TIME

    write_status_file

    notify_status $OLD_STATUS $OLD_STATUS_TIME $NEW_STATUS $NEW_STATUS_TIME
}

notify_status() {
    local OLD=$1
    local OLD_TIME=$2
    local NEW=$3
    local NEW_TIME=$4

    local -A NOTIFY_STATUS

    case $NEW in
        OK)
            NOTIFY_STATUS["OK"]=1
            if [[ $OLD = "ERROR" ]] || [[ $OLD = "UNKNOWN" ]]; then
                NOTIFY_STATUS["RECOVER"]=1
            fi
            ;;
        ERROR|UNKNOWN)
            NOTIFY_STATUS["$NEW"]=1
            if [[ $OLD = "OK" ]]; then
                NOTIFY_STATUS["NEWPROB"]=1
            fi
            ;;
    esac

    #do_email_notification $OLD $OLD_TIME $NEW $NEW_TIME $NOTIFY_STATUS
}

do_email_notification() {
    local OLD=$1
    local OLD_TIME=$2
    local NEW=$3
    local NEW_TIME=$4
    local -A NOTIFY_STATUS=$5
    local SEND

    for notifyState in $EMAIL_NOTIFY; do
        if [[ "$notifyState" = "NEVER" ]]; then
            debug "Email notification set to never"
            return
        fi

        if [[ $NOTIFY_STATUS[$notifyState] ]]; then
            SEND=1
        fi
    done

    if [[ "$SEND" ]]; then
        local TMPFILE=$(mktemp /tmp/$SHNAME-email_notication-XXXXXX)
        local EMAIL_SUBJECT='Mini-CI Notification - $(basename $JOB_DIR)'
        EMAIL_SUBJECT=$(eval echo $EMAIL_SUBJECT)
        cat > $TMPFILE <<EOF
Mini-CI Job Directory: $(pwd)
New State: $NEW
Old State: $OLD
EOF
        for address in $EMAIL_ADDRESS; do
            debug "Mailing notification to $address"
            (mail -s "$EMAIL_SUBJECT" $address < $TMPFILE; rm -f $TMPFILE) &
            add_child $! ""
        done
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

    cd -
}

status() {
    debug ${!CUR_STATUS[@]}
    log "PID:$$ State:$STATE Queue:[${QUEUE[@]}] Poll:${CUR_STATUS[poll]} Update:${CUR_STATUS[update]} Tasks:${CUR_STATUS[tasks]}" #
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
                    queue "$CMD";;
                status)
                    status;;
                abort)
                    abort;;
                reload)
                    reload_config;;
                quit|shutdown)
                    RUN=no
                    break
                    ;;
                *)
                    warning "Unknown command $CMD";;
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
                clean;;
            poll)
                repo_poll_start;;
            update)
                repo_update_start;;
            tasks)
                tasks_start;;
            *)
                error "Unknown job in queue: $CMD";;
        esac
    done
}

reload_config() {
    log "Reloading configuration"
    load_config
    # Abort needs to be after reading the config file so that the
    # status directory is valid.
    abort

    acquire_lock
}

load_config() {
    CONTROL_FIFO="./control.fifo"
    PID_FILE="./mini-ci.pid"
    WORK_DIR="./workspace"
    TASKS_DIR="./tasks.d"
    STATUS_FILE="./status"
    LOG_DIR="./log"
    POLL_LOG="${LOG_DIR}/poll.log"
    UPDATE_LOG="${LOG_DIR}/update.log"
    TASKS_LOG="${LOG_DIR}/tasks.log"
    POLL_FREQ=0
    EMAIL_NOTIFY="NEWERROR, RECOVER"
    EMAIL_ADDRESS=""

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

    # Fix up variables
    EMAIL_NOTIFY=${EMAIL_NOTIFY//,/ /}
    EMAIL_NOTIFY=${EMAIL_NOTIFY^^[[:alpha:]]}
    EMAIL_ADDRESS=${EMAIL_ADDRESS//,/ /}

    if [[ -z $EMAIL_ADDRESS ]]; then
        EMAIL_ADDRESS=$(whoami)
    fi


    export CONTROL_FIFO
    export WORK_DIR
    export TASKS_DIR
    export WORK_DIR
    export LOG_DIR
    export STATUS_FILE
    export POLL_LOG
    export UPDATE_LOG
    export TASKS_LOG
    export POLL_FREQ
    export EMAIL_NOTIFY
    export EMAIL_ADDRESS
}

acquire_lock() {
    CUR_PID=$BASHPID
    if [[ -e $PID_FILE ]]; then
        TEST_PID=$(< $PID_FILE)
        if [[ $TEST_PID && $TEST_PID -ne $CUR_PID ]]; then
            debug "Lock file present $PID_FILE, has $TEST_PID"
            if kill -0 $TEST_PID >/dev/null 2>&1; then
                if [[ $OKNODO = "yes" ]]; then
                    debug "Unable to acquire lock.  Is minici running as PID ${TEST_PID}?"
                    exit 0
                else
                    error "Unable to acquire lock.  Is minici running as PID ${TEST_PID}?"
                fi
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

    read_status_file

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

    cd -
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

    cd -
}

send_message() {
    local cmd=$1

    case $cmd in
        status|poll|update|tasks|clean|abort|quit|shutdown|reload)
        ;;
        *)
            error "Unknown command $cmd"
            ;;
    esac

    local END_TIME=$(( $(printf '%(%s)T\n' -1) + $TIMEOUT))
    (echo $@ > $CONTROL_FIFO) &
    local ECHO_PID=$!

    while [[ $(printf '%(%s)T\n' -1) -lt $END_TIME ]]; do
        if ! kill -0 $ECHO_PID >/dev/null 2>&1; then
            break
        fi
        sleep 1
    done

    if kill -0 $ECHO_PID >/dev/null 2>&1; then
        kill -KILL $ECHO_PID
        error "Timeout writing $cmd to $CONTROL_FIFO"
    fi

    wait $ECHO_PID
    if [[ $? -ne 0 ]]; then
        error "Error writing to $CONTROL_FIFO"
    fi
}


start() {
    TEMP=$(getopt -o c:,d:,m::,o,D,F,h --long timeout:,config-file:,job-dir:,message::,oknodo,debug,foreground,help -n 'test.sh' -- "$@")
    eval set -- "$TEMP"

    MESSAGE=no
    TIMEOUT=5
    DEBUG=no
    DAEMON=yes
    JOB_DIR="."
    CONFIG="config"
    OKNODO=no

    while true; do
        case "$1" in
            -c|--config-file)
                CONFIG_FILE=$2; shift 2;;
            -d|--job-dir)
                JOB_DIR=$2; shift 2;;
            -m|--message)
                MESSAGE=yes
                if [[ "$2" ]]; then
                    TIMEOUT=$2
                fi
                shift 2
                ;;
            -o|--oknodo)
                OKNODO=yes; shift 1;;
            -D|--debug)
                DEBUG=yes; shift 1;;
            -F|--foreground)
                DAEMON=no; shift 1;;
            -h|--help)
                help
                exit 0
                ;;
            --)
                shift ; break ;;
            *)
                echo "ERROR: Problem parsing arguments" 1>&2; exit 1;;
        esac
    done

    cd $JOB_DIR
    load_config

    if [[ $MESSAGE = "yes" ]]; then
        unset MINICI_LOG
        if [[ ! -e $CONTROL_FIFO ]]; then
            error "Control fifo $CONTROL_FIFO is missing"
        fi

        for cmd in $@; do
            send_message $cmd
        done
        exit 0
    fi

    acquire_lock

    for cmd in $@; do
        queue $cmd
    done

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

start $@
