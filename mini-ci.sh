#!/bin/bash
#
# Mini-CI is a small daemon to perform continuous integration (CI) for
# a single repository/project.
#
# AUTHOR: Andrew Phillips <theasp@gmail.com>
# LICENSE: GPLv2

declare -x MINI_CI_DIR=./share
declare -x MINI_CI_VER=unknown

source $MINI_CI_DIR/mini-ci.sh

main "$@"

# Local Variables:
# sh-basic-offset: 2
# sh-indentation: 2
# indent-tabs-mode: nil
# End:
