# The website counts visits with cookieless PostHog

2026-11-16. The site counts visits and a few named clicks with PostHog, as showrecorder.app does, in cookieless mode with memory persistence: no cookies, an anonymous daily hash, no address kept, and no autocapture or recordings (#170). The privacy page says so, and check_site requires it to. The web capture adds only "started" and "finished" events, never MIDI or the controller's name (#190). The app itself collects no data.
