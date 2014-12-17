                           ━━━━━━━━━━━━━━━━━
                                MINI-CI


                            Andrew Phillips
                           ━━━━━━━━━━━━━━━━━


Table of Contents
─────────────────

1 Introduction
2 Features
3 Usage
4 Configuration
5 Examples





1 Introduction
══════════════

  Mini-CI is a small daemon to perform continuous integration (CI) for a
  single repository/project.  Most other CI software is complicated to
  setup and use due to feature bloat and hiding what is going on
  underneath with GUIs.  If you know how to build your project from the
  command line, setting up Mini-CI should be easy.


2 Features
══════════

  • NO web interface!
    • Configuration is done with a small config file and shell scripts.
    • Daemon controlled through a command.
  • NO user authentication!
    • Unix already has multiple users, use groups or make a shared
      account.
  • NO support for multiple projects!
    • You can run it more than once…
  • Low resource requirements.
    • Just a small bash script.
  • Can monitor any repository and use any build system.
    • The only limits are the scripts you provide.


3 Usage
═══════

  ┌────
  │ ./mini-ci --help
  └────

  Usage: mini-ci [option …] [command …]

  Options: -d|–job-dir <dir> directory for job -c|–config-file <file>
  config file to use, relative to job-dir -m|–message [timeout]  send
  commands to running daemon, then exit -o|–oknodo  exit quietly if
  already running -D|–debug  log debugging information -F|–foreground
  do not become a daemon, run in foreground -h|–help  show usage
  information and exit

  Commands: status  log the current status poll  poll the source code
    repository for updates, queue update if updates are available update
    update the source code repository, queue tasks if updates are made
    tasks  run the tasks in the tasks directory clean  remove the work
    directory abort  abort the currently running command quit|shutdown
    shutdown the daemon, aborting any running command reload  reread the
    config file, aborting any running command

  Commands given while not in message mode will be queued.  For instance
  the following command will have a repository polled for updates (which
  will trigger update and tasks if required) then quit.  mini-ci -d
  <dir> -F poll quit


4 Configuration
═══════════════


5 Examples
══════════
