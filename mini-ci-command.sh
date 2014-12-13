#!/bin/bash

TIMEOUT=5

while getopts ":t:d:f:c:" opt; do
    case $opt in
        t)
            TIMEOUT=$OPTARG
            ;;
        c)
            CONFIG_FILE=$OPTARG
            ;;
        d)
            JOB_DIR=$OPTARG
            ;;
        f)
            CONTROL_FIFO=$OPTARG
            ;;
        \?)
            echo "Invalid option: -$OPTARG" >&2
            exit 1
            ;;
        :)
            echo "Option -$OPTARG requires an argument." >&2
            exit 1
            ;;
    esac
done
shift $((OPTIND-1))


if [[ ! $CONTROL_FIFO ]]; then
    if [[ ! $CONFIG_FILE ]]; then
        if [[ $JOB_DIR ]]; then
            CONFIG_FILE="$JOB_DIR/config"
            CONTROL_FIFO="$JOB_DIR/control.fifo"
        else
            JOB_DIR='./'
            CONFIG_FILE="./config"
            CONTROL_FIFO="./control.fifo"
        fi
    fi

    if [[ -e $CONFIG_FILE ]]; then
        source $CONFIG_FILE
    fi
fi

if [[ -z $CONTROL_FIFO ]]; then
    echo "ERROR: Unable to determine control fifo" 1>&2
    exit 1
fi

if [[ ! -e $CONTROL_FIFO ]]; then
    echo "ERROR: Control fifo $CONTROL_FIFO is missing" 1>&2
    exit 1
fi

killtree() {
    local _pid=$1
    local _sig=${2:--TERM}
    kill -stop ${_pid} # needed to stop quickly forking parent from producing children between child killing and parent killing
    for _child in $(pgrep -P ${_pid}); do
        killtree ${_child} ${_sig}
    done
    kill -${_sig} ${_pid}
}

for cmd in $@; do
    case $cmd in
        status|poll|update|tasks|abort|quit|shutdown|reload)
        ;;
        *)
            echo "ERROR: Unknown command $cmd" 1>&2
            exit 1
            ;;
    esac

    END_TIME=$(( $(printf '%(%s)T\n' -1) + $TIMEOUT))
    (echo $@ > $CONTROL_FIFO) &
    ECHO_PID=$!

    while [[ $(printf '%(%s)T\n' -1) -lt $END_TIME ]]; do
        if ! kill -0 $ECHO_PID >/dev/null 2>&1; then
            break
        fi
        sleep 1
    done

    if kill -0 $ECHO_PID >/dev/null 2>&1; then
        echo "ERROR: Timeout writing $cmd to $CONTROL_FIFO" 1>&2
        kill -KILL $ECHO_PID
        exit 1
    fi

    wait $ECHO_PID
    if [[ $? -ne 0 ]]; then
        echo "ERROR: Error writing to $CONTROL_FIFO" 1>&2
        exit 1
    fi
done
