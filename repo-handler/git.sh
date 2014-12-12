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

        LOCAL=$(git rev-parse @)
        REMOTE=$(git rev-parse @{u})
        BASE=$(git merge-base @ @{u})

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
