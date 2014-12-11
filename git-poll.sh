#!/bin/bash

set -e

# Prints the following:
# OK CURRENT - No update detected
# OK NEEDED- Update detected
# ERR LOCALCOMMITS - Local commits detected
# ERR DIVERGED - Remote and local have diverged
# ERR UNKNOWN - Unable to update

DIR=$1
REPO=$2

if [ "$DIR" ]; then
    cd $DIR
fi

if ! git remote update; then
    echo "ERR UPDATE"
    exit 1
fi

LOCAL=$(git rev-parse @)
REMOTE=$(git rev-parse @{u})
BASE=$(git merge-base @ @{u})

echo "Local: $LOCAL"
echo "Remote: $REMOTE"
echo "Base: $BASE"

if [ $LOCAL = $REMOTE ]; then
    echo "OK CURRENT"
    exit 0
elif [ $LOCAL = $BASE ]; then
    echo "OK NEEDED"
    exit 0
elif [ $REMOTE = $BASE ]; then
    echo "ERR LOCALCOMMITS"
    exit 1
else
    echo "ERR DIVERGED"
    exit 1
fi
