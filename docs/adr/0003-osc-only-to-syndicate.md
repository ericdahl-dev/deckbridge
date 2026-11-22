# DeckBridge talks to Syndicate over OSC only

2026-11-16. DeckBridge reads the controller's MIDI itself and drives Syndicate only through its OSC input and feedback (#12). Syndicate's own MIDI mapping can't read 14-bit control pairs or relative encoders, and gives LED feedback only to the DDJ-FLX4 and FLX10 (Syndicate User Guide 0.3.7, section 13.9, cited in #220), so passing MIDI through wasn't an option. Users turn the controller's MIDI input off in Syndicate, so the two never both react to a button.
