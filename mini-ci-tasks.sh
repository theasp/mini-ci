#!/bin/bash

set -e

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
_MINICI_LOG_CONTEXT="$_MINICI_JOB_NAME/tasks($$)"

if [[ -z "$_MINICI_JOB_DIR" ]]; then
    error "Unable to determine job directory"
fi

if [[ -z "$_CONFIG" ]]; then
    error "Unable to determine job configuration file"
fi

_start() {
    log "Starting up"

    # Defaults
    WORKSPACE="$_MINICI_JOB_DIR/workspace"
    TASKS_DIR="$_MINICI_JOB_DIR/tasks.d"
    LOG_DIR="$_MINICI_JOB_DIR/tasks.logs"
    WANTED_RE='^[a-zA-Z0-9_-]+$'

    if [[ ! -d $TASKS_DIR ]]; then
        error "Can't find tasks directory $TASKS_DIR"
    fi

    if [[ ! -d $TASKS_DIR ]]; then
        mkdir $LOG_DIR
    fi

    for file in $(ls -1 $TASKS_DIR | grep -e $WANTED_RE | sort); do
        if [[ -x $file ]]; then
            LOG=$LOG_DIR/$(basename $file)
            log "Running $file"
            if ! $file > $LOG 2>&1; then
                error "Bad return code $?"
            fi
        fi
    done
}


_start
