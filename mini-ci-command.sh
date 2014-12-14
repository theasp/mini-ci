#!/bin/bash

set -e

TIMEOUT=5

SHNAME=$(basename $0)

TEMP=$(getopt -o t:,c:,d:,f:, --long timeout:,config-file:,job-dir:,control-fifo: -n $SHNAME -- "$@")
eval set -- "$TEMP"

while true; do
    case "$1" in
        -t|--timeout)
            TIMEOUT=$2; shift 2;;
        -c|--config-file)
            CONFIG_FILE=$2; shift 2;;
        -d|--job-dir)
            JOB_DIR=$2; shift 2;;
        -f|--control-fifo)
            CONTROL_FIFO=$2; shift 2;;
        --)
            shift ; break ;;
        *)
            echo "ERROR: Problem parsing arguments" 1>&2; exit 1;;
    esac
done


if [[ ! $CONTROL_FIFO ]]; then
    CONTROL_FIFO="control.fifo"
    if [[ $CONFIG_FILE ]]; then
        if [[ ! $JOB_DIR ]]; then
            JOB_DIR=$(dirname $CONFIG_FILE)
        fi
    else
        CONFIG_FILE="config"
        if [[ ! $JOB_DIR ]]; then
            JOB_DIR='./'
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

if [[ "$JOB_DIR" ]]; then
    cd $JOB_DIR
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
        status|poll|update|tasks|clean|abort|quit|shutdown|reload)
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
