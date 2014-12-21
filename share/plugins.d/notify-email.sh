declare EMAIL_ADDRESS
declare EMAIL_NOTIFY
declare EMAIL_SUBJECT

plugin_on_load_config_pre_notify_email() {
  EMAIL_ADDRESS=""
  EMAIL_NOTIFY="NEWPROB, RECOVER"
  EMAIL_SUBJECT=""
}

plugin_on_load_config_post_notify_email() {
  EMAIL_NOTIFY=${EMAIL_NOTIFY//,/ /}
  EMAIL_NOTIFY=${EMAIL_NOTIFY^^[[:alpha:]]}
  EMAIL_ADDRESS=${EMAIL_ADDRESS//,/ /}

  if [[ -z "$EMAIL_ADDRESS" ]]; then
    EMAIL_ADDRESS="$(whoami)"
  fi

  if [[ -z "$EMAIL_SUBJECT" ]]; then
    EMAIL_SUBJECT="Mini-CI Notification - $JOB_NAME"
  fi
}

plugin_notify_email() {
  local item=$1
  local old=$2
  local old_time=$3
  local new=$4
  local new_time=$5
  local active_states=$6
  local send_reason

  if [[ -z "$EMAIL_NOTIFY" ]]; then
    debug "EMAIL_NOTIFY not set, returning"
    return 0
  fi

  for notifyState in $EMAIL_NOTIFY; do
    if [[ "$notifyState" = "NEVER" ]]; then
      debug "Email notification set to never"
      return 0
    fi

    for i in $active_states; do
      if [[ "$i" = "$notifyState" ]]; then
        send_reason=$notifyState
        break
      fi
    done

    if [[ -n "$send_reason" ]]; then
      break
    fi
  done

  if [[ -n "$send_reason" ]]; then
    local tmpfile=$(mktemp /tmp/$SHNAME-email_notication-XXXXXX)
    local email_subject="Mini-CI Notification - $JOB_NAME"
    cat > $tmpfile <<EOF

This copy of Mini-CI is running on $(hostname -f) as user $(whoami).

Mini-CI Job Directory: $(pwd)
Item: $item
Reason: $send_reason
New State: $new
Old State: $old
EOF

    case $item in
      poll)
        echo >> $tmpfile
        echo "Poll Log:" >> $tmpfile
        cat $POLL_LOG >> $tmpfile
        ;;
      update)
        echo >> $tmpfile
        echo "Update Log:" >> $tmpfile
        cat $UPDATE_LOG >> $tmpfile
        ;;
      tasks)
        echo "Build Number: $BUILD_NUMBER" >> $tmpfile
        echo "Build Log Directory: $BUILD_LOG_DIR" >> $tmpfile
        echo >> $tmpfile
        echo "Update Log:" >> $tmpfile
        cat $UPDATE_LOG >> $tmpfile
        echo >> $tmpfile
        echo "Tasks Log:" >> $tmpfile
        cat $TASKS_LOG >> $tmpfile
        local last_task_log=$(ls -1 $BUILD_LOG_DIR/ | grep '^task-.*\.log$' | sort | tail -n 1)
        if [[ -n "$last_task_log" ]]; then
          echo >> $tmpfile
          echo "Last task log: ($last_task_log)" >> $tmpfile
          tail -n 100 "$BUILD_LOG_DIR/$last_task_log" >> $tmpfile
        fi
    esac

    for address in $EMAIL_ADDRESS; do
      log "Mailing $item notification to $address due to $send_reason (New:$new Old:$old)"
      (mail -s "$EMAIL_SUBJECT" $address < $tmpfile; rm -f $tmpfile) &
      add_child $! ""
    done
  fi
}

# Local Variables:
# sh-basic-offset: 2
# sh-indentation: 2
# indent-tabs-mode: nil
# End:
