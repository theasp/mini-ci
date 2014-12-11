#!/bin/bash

set -e

DIR=$1
REPO=$2

if [ -z "$_MINICI_LIBDIR" ]; then
    echo "ERROR: LIBDIR not set.  Not running inside of mini-ci?" 1>&2
    exit 1
fi

source $_MINICI_LIBDIR/functions.sh

if [ -z "$DIR" ]; then
    error "Missing argument DIR"
fi

if [ -z "$REPO" ]; then
    error "Missing argument REPO"
fi


test -d $DIR || mkdir $DIR
cd $DIR
git clone $REPO .
