error() {
    log "ERROR: $@"
    exit 1
}

debug() {
    if [ "$_MINICI_DEBUG" = "yes" ]; then
        log "DEBUG: $@"
    fi
}

warning() {
    log "WARN: $@"
}

log() {
    if [ "$_MINICI_LOG_CONTEXT" ]; then
        msg="$_MINICI_LOG_CONTEXT $@"
    else
        msg="$@"
    fi
    echo "$(date +%F-%T)" $msg 1>&2
}
