#!/bin/bash
set -e

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

OPERATION=$1
DIR=$2
REPO=$3

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
        LOCAL=$(svn info | grep '^Last Changed Rev' | cut -f 2 -d :)
        REMOTE=$(svn info -r HEAD| grep '^Last Changed Rev' | cut -f 2 -d :)

        echo "Local: $LOCAL"
        echo "Remote: $REMOTE"

        if [ $LOCAL -eq $REMOTE ]; then
            echo "OK POLL CURRENT"
            exit 0
        elif [ $LOCAL = $BASE ]; then
            echo "OK POLL NEEDED"
            exit 0
        fi
        ;;
    *)
        error "Unknown operation $OPERATION"
        ;;
esac
