/*
  delight.js - the home page's small moments (#753), beside its two data-moments (a page holds at most two).

  The console's hello, with the app's own default ports (ProfileKeys: osc.port 9090, osc.feedback_port 9096).

  The 7-bit and 14-bit faders in #why: one scroll scrub moves both caps the same way. The 7-bit cap lands only on
  its 128 positions, so it steps; the 14-bit cap has 16,384, so it glides. Under reduced motion both sit still at the
  same spot, and without this script they sit there too (site.css's --p default).
*/
import * as lib from './moments/lib.js';

console.info("DeckBridge: OSC out on 9090, feedback in on 9096. Hello, fellow tinkerer.");

const STILL = 0.62;
const faders = [...document.querySelectorAll('.db-fader')];
const host = document.getElementById('why');

function place(progress) {
  for (const fader of faders) {
    const last = Number(fader.dataset.steps) - 1;
    fader.style.setProperty('--p', (Math.round(progress * last) / last).toFixed(5));
  }
}

place(STILL);
if (host && faders.length && !lib.reduced()) {
  // From well below the middle of the screen to well above it: one full sweep while the section passes.
  lib.scrub(host, p => place(lib.ease.smooth(0.15, 0.85, p)), { mode: 'view' });
}
