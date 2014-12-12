                           ━━━━━━━━━━━━━━━━━
                                MINI-CI


                            Andrew Phillips
                           ━━━━━━━━━━━━━━━━━


Table of Contents
─────────────────

1 Introduction
2 Features
3 Configuration
4 Examples





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


3 Configuration
═══════════════


4 Examples
══════════
