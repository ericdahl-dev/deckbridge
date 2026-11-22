# A release tag goes to TestFlight Internal only, unless it asks for external

2026-11-16. After a tag meant for internal testing was submitted for Beta App Review by mistake (#244), a `v*` tag now distributes to Internal only. External distribution and Beta App Review happen only when the tag annotation says `[external]` or a manual run asks for it (#249, #180). The safe path is the default because an external submission can't be taken back.
