# The jog display is driven over its WD port, and is off until the user turns it on

2026-11-16. The LC6000's jog display takes images over its own WD port after a host hello (#121, #165). Before any timing spike or hardware check had run, every build with an LC6000 attached would have said hello and uploaded, so the unit was getting unverified hardware sends. Settings' "Show the deck on the jog display" is therefore off by default, and the user kept it that way (#165): while it's off, nothing reaches either port, not even the hello, and a test guards that. The app still renders and previews every deck in Diagnostics either way, so the display can be checked without risk.

2026-11-17. After the v1.1 hardware check passed on the user's LC6000 (#165), the switch is on by default for new settings. Settings saved before it keep the choice they had: a missing key still reads as off. The guard stays: with the switch off, nothing reaches either port.
