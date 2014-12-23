#!/bin/bash
set -ex

export MINI_CI_DIR=${MINI_CI_DIR:-"$PWD/share"}

TEST_DIR=./tests
for test in $(ls -1 $TEST_DIR | grep -E -e '^[a-zA-Z0-9_-]+$' | sort); do
    $TEST_DIR/$test
done
