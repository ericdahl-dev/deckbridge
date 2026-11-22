# Capture is in the app first, the browser is optional, and nothing is uploaded

2026-11-16. New controllers are added from owners' captures (#184). The guided capture lives in the app first (#186), with a browser version on the site for owners without the app (#190), both writing the same capture file and walking the same prompt list. The file is saved locally and reaches us only if the owner emails it; the web capture asks for MIDI only after Start and never for SysEx. We chose this over an automatic upload so that no MIDI or device data leaves anyone's machine without them sending it.
