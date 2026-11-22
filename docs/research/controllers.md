# Which controllers to support next, and their public MIDI sources

Research for [#191](https://github.com/ericdahl-dev/deckbridge/issues/191) (parent [#184](https://github.com/ericdahl-dev/deckbridge/issues/184)). It feeds [#202](https://github.com/ericdahl-dev/deckbridge/issues/202), the first new controller profile, and [#207](https://github.com/ericdahl-dev/deckbridge/issues/207), the mixer section. Sources were gathered on 2026-11-16.

## 1. Question, method, licensing

**Question.** After the LC6000 work in [#48](https://github.com/ericdahl-dev/deckbridge/issues/48), which controllers should DeckBridge support next? For each one, how much of a profile can we draft from public documents before anyone captures MIDI from the hardware?

**Method.**
- **Syndicate's own coverage.** I tried to find Syndicate's controller support list on its own site.
- **Manufacturer MIDI charts.** I collected the Pioneer DJ / AlphaTheta "List of MIDI messages" PDFs and the Denon DJ / inMusic MIDI specifications and command lists.
- **Mixxx mappings.** I read Mixxx's controller mappings in `mixxxdj/mixxx` at commit [`dc4bf99`](https://github.com/mixxxdj/mixxx/tree/dc4bf99322bb9a4c59483d24c2c40d1df2d1b726/res/controllers), plus the Mixxx manual's hardware pages ([`mixxxdj/manual`](https://github.com/mixxxdj/manual/tree/main/source/hardware/controllers)).
- **Forum posts** are used only where nothing primary exists, and are labeled as forum posts.
- **Profile fit.** Each candidate is checked against what a DeckBridge profile can express today. That covers `main` plus the profile keys merged since: [#193](https://github.com/ericdahl-dev/deckbridge/issues/193) encoder format, [#204](https://github.com/ericdahl-dev/deckbridge/issues/204) relative jog and [#194](https://github.com/ericdahl-dev/deckbridge/issues/194) LED levels.

**Licensing.** MIDI numbers are facts. This document states them in our own words, in short tables, and gives the source of each one. It does not copy any Mixxx mapping file (GPL XML/JS), any code or comments from them, or any manufacturer PDF text. Profiles written from these facts must be written by us, with each number traced to the source listed here.

**What counts as popularity evidence.** I found no first-party sales figures. Popularity is judged from things I can cite:
- the manufacturer calling a model its entry-level standard;
- the model being a current entry-level product;
- official support from several DJ apps;
- a Mixxx mapping existing.

No rank depends on retailer charts or press "best-selling" claims.

## 2. What Syndicate itself supports

Source: Syndicate's own user guide, build 0.3.7 (macOS public beta, updated Nov 14, 2026). Its section 13.9, "What's supported" ([Syndicate User Guide 0.3.7, section 13.9](https://untitledaudiosyndicate.com/user-guide/index.html#c13-9)), is the controller list. The guide loads inside the /docs page from [/user-guide/index.html](https://untitledaudiosyndicate.com/user-guide/index.html), which is why a fetch without a browser saw only the site navigation.

- **Presets with LED feedback: only the DDJ-FLX4 and DDJ-FLX10.** Mapping → CHOOSE PRESET loads a preset for either model, with "their supported MIDI LED feedback" (section 13.1). Section 13.9 lists generic LED or motor feedback over MIDI as **not supported**. So our README's claim holds.
- **The preset is picked by hand.** The user chooses the model in CHOOSE PRESET; the guide doesn't describe matching by device name. A user could load the FLX4 preset for another controller.
- **Generic user mapping (section 13.9).**
  - Supported: absolute MIDI CC 0–119, note on/off with velocity, pitch wheel (14-bit), and the DDJ-FLX4/FLX10 jog and browse CCs.
  - Not supported: 14-bit CC pairs, NRPN, generic relative or encoder CC, soft takeover, and MIDI shift layers or banks.
- **What that means for a controller without a preset:**
  - its 14-bit CC-pair faders and jogs reduce to their 7-bit MSB, or don't work;
  - its relative jog doesn't work;
  - its LEDs stay dark;
  - its Shift layer isn't available.
  
  The LC6000's jog and pitch are 14-bit CC pairs, which is why Syndicate's own mapping can't read them at full resolution.
- **OSC feedback** for other surfaces is configurable (section 14.10, linked from 13.1). DeckBridge uses this.

## 3. Ranked top 10

Each controller is scored on four things:
- **(a) Popularity**, from the evidence above.
- **(b) The Syndicate gap:** how badly Syndicate's own mapping serves it.
- **(c) Docs coverage:** how much of a profile public docs can draft.
- **(d) Fit:** USB-MIDI (DeckBridge can't speak HID) and how many new profile keys it needs.

(b) is weighted above (a). DeckBridge exists to cover what Syndicate doesn't, so a popular controller that Syndicate already lights ranks below a slightly less popular one that it doesn't.

| # | Controller | Why here |
|---|---|---|
| 1 | **Pioneer DJ DDJ-400** | Pioneer itself calls it its standard entry-level controller, in the [FLX4 launch news (2022-11-08, German)](https://www.pioneerdj.com/de/news/2022/ddj-flx4-2-channel-dj-controller-for-multiple-dj-applications/), which says the FLX4 keeps the DDJ-400's main layout features. Press coverage calls the FLX4 its replacement ([Digital DJ Tips](https://www.digitaldjtips.com/pioneer-dj-replaces-ddl-400-with-new-more-versatile-ddj-flx4/), secondary). The size of its installed base is my inference, not a cited figure. It is not one of the two units our README says Syndicate lights. Its MIDI is almost the same as the FLX4's: Mixxx's DDJ-400 and FLX4 mappings share 193 of the DDJ-400's 199 input messages and all 110 of its LED outputs (my comparison of the two XML files at `dc4bf99`). So the FLX4's official MIDI list documents most of it. |
| 2 | **Pioneer DJ DDJ-FLX4** | A current Pioneer 2-channel controller aimed at beginners ([launch news](https://www.pioneerdj.com/de/news/2022/ddj-flx4-2-channel-dj-controller-for-multiple-dj-applications/); [product page](https://www.pioneerdj.com/en/product/dj-controllers/ddj-flx4/)). Officially supported by several apps: [djay](https://www.pioneerdj.com/en/news/2023/ddj-flx4-officially-supports-djay) and [Traktor Play](https://www.pioneerdj.com/ja/news/2025/ddj-flx2-and-ddj-flx4-support-traktor-play/). It has the best public docs of any candidate (official MIDI list, Mixxx mapping and Mixxx manual page). It ranks below the DDJ-400 only because Syndicate already has a preset that lights it (section 2). |
| 3 | **Denon DJ MC7000** | Denon's 4-deck Serato controller ([product page](https://www.denondj.com/professional-dj-controller-for-serato-mc7000xus)). I found no popularity evidence for it; its rank rests on family fit and docs. It is not one of the two units our README says Syndicate lights. It is an inMusic sibling of the LC6000: two's-complement jog, a 2-bit-per-channel RGB pad color byte like our provisional LC6000 table, MIDI channel = deck, and a startup SysEx with the same `00 20 7F` manufacturer ID as the LC6000's host hello (sources in section 4). Denon publishes no MIDI chart for the MC7000 itself. But its official [MCX8000 MIDI command list](https://cdn.inmusicbrands.com/denondj/MCX8000/Denon_DJ_MCX8000_MIDI_Command_List_v1.0.pdf) uses the same numbers that Mixxx uses for the MC7000, so it serves as an official sibling proxy (section 4). |
| 4 | **Denon PRIME standalone units in computer mode** (SC6000/SC6000M, Prime 4/4+, Prime 2, Prime Go/Go+, SC Live 2/4) | These are the LC6000's closest relatives and natural partners for LC6000 owners. Without a mixer, the SC6000 would let us ship without [#207](https://github.com/ericdahl-dev/deckbridge/issues/207). But Denon's [downloads page](https://www.denondj.com/downloads.html) lists a MIDI specification only for the LC6000 among PRIME products, and Mixxx has no mapping for any of them. Docs coverage is close to zero, so it ranks below the MC7000 despite the family fit. |
| 5 | **Numark Mixtrack Platinum FX** (and **Mixtrack Pro FX**) | Numark's current Mixtrack FX controllers ([Platinum FX](https://www.numark.com/product/mixtrack-platinum-fx), [Pro FX](https://www.numark.com/product/mixtrack-pro-fx)). The Pro FX has 2 decks; the Mixxx manual calls the Platinum FX a 4-deck unit. My only popularity evidence is that both are current products. Not one of the units our README says Syndicate lights. Both have Mixxx mappings and Mixxx manual pages. Same inMusic traits as the MC7000: two's-complement jog, the `00 20 7F` status SysEx, and VU on CC 0x1F. No Numark MIDI chart found. |
| 6 | **Hercules DJControl Inpulse 500** (and **300**) | Hercules' mid and entry DJUCED/Serato controllers ([Inpulse 500 support](https://support.hercules.com/en/product/djcontrolinpulse500-en/)). Mixxx mappings exist for both. Hercules publishes a [function manual](https://www.djuced.com/kb/hercules-djcontrol-inpulse-500/) but I found no MIDI numbers in it. RGB pads need a color table that only Mixxx documents. |
| 7 | **Pioneer DJ DDJ-REV1** (and REV5/REV7) | Pioneer's Serato battle-layout line. Official MIDI lists exist (archived). No Mixxx mapping. The REV1 is the entry model. Its rank is a judgment call: I found no popularity evidence beyond it being the current entry model of the line. |
| 8 | **Pioneer DJ DDJ-1000** (and DDJ-SX3) | 4-channel rekordbox and Serato flagships with official MIDI lists (archived). The lists reference a 1–127 pad color number but contain no color table. The DDJ-1000 has jog displays with no public protocol. No Mixxx mapping for either; Mixxx maps only the older DDJ-SX. |
| 9 | **Pioneer DJ DDJ-FLX6** | 4-deck FLX with an official MIDI list (archived). Not one of the units our README says Syndicate lights. No Mixxx mapping. |
| 10 | **Native Instruments Traktor Kontrol S2 MK3 / S3** | NI documents a MIDI mode for the S2 MK3 and S3: hold the left FLX button while connecting ([NI support](https://support.native-instruments.com/support/solutions/articles/69000880031-native-instruments-switching-your-controller-to-midi-mode)). But I found no published MIDI assignment for that mode, and Mixxx's mappings use HID instead ([S2 MK3 manual page](https://github.com/mixxxdj/manual/blob/main/source/hardware/controllers/native_instruments_traktor_kontrol_s2_mk3.md)). So it would be capture-only. |

**Considered and left out**
- **Pioneer DDJ-FLX10.** Syndicate already has a preset with LED feedback for it (section 2). There is an official MIDI list, but the archived copy is truncated (see sources).
- **Pioneer DDJ-FLX2.** A current entry FLX model (named in the [Traktor Play news](https://www.pioneerdj.com/ja/news/2025/ddj-flx2-and-ddj-flx4-support-traktor-play/)). No MIDI list was found in the archive under Pioneer's usual path, and Mixxx has no mapping.
- **Traktor Kontrol S4 MK3.** It isn't in NI's MIDI-mode table, and Mixxx drives it over HID and USB bulk ([manual page](https://github.com/mixxxdj/manual/blob/main/source/hardware/controllers/native_instruments_traktor_kontrol_s4_mk3.md)). DeckBridge is MIDI-only.
- **Rane One / Four / Seventy.** No manufacturer MIDI chart found and no Mixxx mapping. Only forum mapping threads exist ([forum, djay](https://community.algoriddim.com/t/rane-one-midi-mapping/26978)).
- **Reloop.** Mixxx maps only older models (Beatmix 2/4 MK2, Mixage, Terminal Mix, Beatpad). A forum post points to a Reloop-hosted MIDI map for the Mixtour ([forum](https://community.algoriddim.com/t/reloop-mixtour-pro-full-midi-map/38993)); unverified for current models.
- **Numark Mixstream Pro.** A standalone Engine unit. A Mixxx mapping exists ([manual page](https://github.com/mixxxdj/manual/blob/main/source/hardware/controllers/numark_mixstream_pro.md)). Lower priority than the Mixtracks.

## 4. Public MIDI sources for each of the top 10

Mixxx links are pinned to commit `dc4bf99`. For Pioneer PDFs, the original `pioneerdj.com` URLs now redirect to `support.alphatheta.com`, which returned 403 to scripted fetches. I read the Internet Archive copies and give both URLs. Three support sites (`support.alphatheta.com`, `support.pioneerdj.com` and `support.hercules.com`) also returned 403 to scripted link checks. Their links come from Mixxx's manual pages and weren't opened.

Each entry below lists the sources first, then the mixer section. "Mixer" means the per-deck mixer controls and the VU meters, for [#207](https://github.com/ericdahl-dev/deckbridge/issues/207).

### 1. DDJ-400

**Sources**
- **Manufacturer chart.** None found. No archived copy under the usual Pioneer path either; the archive's index was offline during this research. Unverified whether one exists.
- **Closest official proxy.** The DDJ-FLX4 list (entry 2), because the two share almost all messages in Mixxx.
- **Mixxx mapping:**
  - [`Pioneer-DDJ-400.midi.xml`](https://github.com/mixxxdj/mixxx/blob/dc4bf99322bb9a4c59483d24c2c40d1df2d1b726/res/controllers/Pioneer-DDJ-400.midi.xml)
  - [`Pioneer-DDJ-400-script.js`](https://github.com/mixxxdj/mixxx/blob/dc4bf99322bb9a4c59483d24c2c40d1df2d1b726/res/controllers/Pioneer-DDJ-400-script.js)
  - [manual page](https://github.com/mixxxdj/manual/blob/main/source/hardware/controllers/pioneer_ddj_400.md), which links Pioneer's [firmware page](https://support.alphatheta.com/products/4416577146009?section=25) and notes that the release firmware had a bug.
- **Startup message.** Mixxx sends one SysEx at startup that asks the unit for its current control positions ([L201–202](https://github.com/mixxxdj/mixxx/blob/dc4bf99322bb9a4c59483d24c2c40d1df2d1b726/res/controllers/Pioneer-DDJ-400-script.js#L201-L202)). Useful for pickup, but not known to be required.

**Mixer**
- **Hardware:** yes. 2 channel faders, trim, 3-band EQ, a filter knob per channel, headphone cue, crossfader and channel VU meters.
- **Docs coverage, via Mixxx:** all 14-bit.
  - Faders: CC 0x13/0x33 on the deck channel.
  - Trim: CC 0x04/0x24.
  - EQ: high, mid and low on CC 0x07, 0x0B and 0x0F, each with LSB +0x20.
  - Filter: CC 0x17/0x37 (deck 1) on MIDI channel 7.
  - Crossfader: CC 0x1F/0x3F on channel 7.
  - Cue: note 0x54.
  - VU: CC 0x02 out on the deck channel ([L57–59](https://github.com/mixxxdj/mixxx/blob/dc4bf99322bb9a4c59483d24c2c40d1df2d1b726/res/controllers/Pioneer-DDJ-400-script.js#L57-L59)).
- **VU scale:** the LED bands aren't documented for the DDJ-400 itself. Assume they match the FLX4's bands (unverified).

### 2. DDJ-FLX4

**Sources**
- **Manufacturer chart.** "DDJ-FLX4 List of MIDI messages", Ver 1.0, 5 pages. Original: `https://www.pioneerdj.com/-/media/pioneerdj/software-info/controller/ddj-flx4/ddj-flx4_midi_message_list_e1.pdf`. [Archived copy (2025-08-05)](https://web.archive.org/web/20250805162346/https://www.pioneerdj.com/-/media/pioneerdj/software-info/controller/ddj-flx4/ddj-flx4_midi_message_list_e1.pdf). The Mixxx manual links the same document.
- **Mixxx mapping:**
  - [`Pioneer-DDJ-FLX4.midi.xml`](https://github.com/mixxxdj/mixxx/blob/dc4bf99322bb9a4c59483d24c2c40d1df2d1b726/res/controllers/Pioneer-DDJ-FLX4.midi.xml)
  - [`Pioneer-DDJ-FLX4-script.js`](https://github.com/mixxxdj/mixxx/blob/dc4bf99322bb9a4c59483d24c2c40d1df2d1b726/res/controllers/Pioneer-DDJ-FLX4-script.js)
  - [manual page](https://github.com/mixxxdj/manual/blob/main/source/hardware/controllers/pioneer_ddj_flx4.md), mapped on firmware 1.02.
- **Other:** Pioneer's [instruction manual article](https://support.pioneerdj.com/hc/en-us/articles/12267724407961-How-to-use-your-Pioneer-DJ-DDJ-FLX4-controller-Instruction-Manual/).

**Mixer**
- **Hardware:** yes. Same mixer as the DDJ-400, plus the Smart Fader and Smart CFX.
- **Docs coverage:** the official list covers all of it (page 2). Every fader and knob is a 14-bit MSB/LSB pair, at the same CC numbers as the DDJ-400 entry.
- **VU:** channel level meter on CC 0x02 per deck channel. The list gives five LED bands, from green up to red, as value ranges between 0x26 and 0x7F (page 2).

### 3. Denon DJ MC7000

**Sources**
- **Official sibling chart.** Denon's [MCX8000 MIDI Command List v1.0](https://cdn.inmusicbrands.com/denondj/MCX8000/Denon_DJ_MCX8000_MIDI_Command_List_v1.0.pdf), 5 pages. I compared it with Mixxx's MC7000 mapping, and every one of these numbers matches:
  - play note 0x00, cue 0x01, platter touch note 0x06, platter CC 0x06;
  - pitch on CC 0x09 and 0x77;
  - trim 0x16, EQ 0x17–0x19, filter 0x1A, fader 0x1C, cue 0x1B;
  - crossfader CC 0x08 on channel 16;
  - decks on channels 1–4, pads on channels 5–8 (p.1).

  It also gives a pad color table with 64 velocities, where 1 is off and the colors are image swatches (p.3), and the meter scales (p.4). That the MC7000 matches it everywhere is unverified; it matches wherever Mixxx touches.
- **Manufacturer chart for the MC7000 itself.** None. Denon publishes only a [hardware settings mode spec](http://cdn.inmusicbrands.com/denondj/MC7000/MC7000-Hardware-Settings-Mode-Specification-v1_4.pdf) (jog touch sensitivity, mic settings and MIDI send interval; no message list) and the [user guide](http://cdn.inmusicbrands.com/denondj/MC7000/MC7000-UserGuide-v1.1.pdf). Both are linked from Mixxx's manual page.
- **Mixxx mapping:**
  - [`Denon-MC7000.midi.xml`](https://github.com/mixxxdj/mixxx/blob/dc4bf99322bb9a4c59483d24c2c40d1df2d1b726/res/controllers/Denon-MC7000.midi.xml)
  - [`Denon-MC7000-scripts.js`](https://github.com/mixxxdj/mixxx/blob/dc4bf99322bb9a4c59483d24c2c40d1df2d1b726/res/controllers/Denon-MC7000-scripts.js)
  - [manual page](https://github.com/mixxxdj/manual/blob/main/source/hardware/controllers/denon_mc7000.md)
- **Family evidence (inMusic):**
  - The color scheme is described in the script ([L176–178](https://github.com/mixxxdj/mixxx/blob/dc4bf99322bb9a4c59483d24c2c40d1df2d1b726/res/controllers/Denon-MC7000-scripts.js#L176-L178)).
  - The startup SysEx uses manufacturer ID `00 20 7F` ([L223–224](https://github.com/mixxxdj/mixxx/blob/dc4bf99322bb9a4c59483d24c2c40d1df2d1b726/res/controllers/Denon-MC7000-scripts.js#L223-L224)). That is the ID #121 found in the LC6000's Serato host hello. Calling `00 20 7F` Serato's ID is #121's reading, not checked against the MIDI Association's ID list.

**Mixer**
- **Hardware:** yes. 4 channel faders, trim, 3-band EQ, filter, cue, crossfader and per-channel VU.
- **Docs coverage, via Mixxx and the MCX8000 list:** all 7-bit.
  - Trim: CC 0x16.
  - EQ: high, mid and low on CC 0x17, 0x18 and 0x19.
  - Filter: CC 0x1A.
  - Fader: CC 0x1C.
  - All of these are on the deck's channel, 1–4.
  - Crossfader: CC 0x08 on channel 16.
  - Cue: note 0x1B.
- **VU:** out on CC 0x1F per deck channel, with 0x76 as the peak (red) value ([L168](https://github.com/mixxxdj/mixxx/blob/dc4bf99322bb9a4c59483d24c2c40d1df2d1b726/res/controllers/Denon-MC7000-scripts.js#L168), [L1100–1106](https://github.com/mixxxdj/mixxx/blob/dc4bf99322bb9a4c59483d24c2c40d1df2d1b726/res/controllers/Denon-MC7000-scripts.js#L1100-L1106)). On the MCX8000, the list documents the channel meter as 10 LEDs. Each value band lights one more LED, and 0x76–0x7F lights all of them (p.4). The master meter is CC 0x19 on channel 16. Mixxx's MC7000 steps of 13 match those bands.

### 4. Denon PRIME units in computer mode

**Sources**
- **Manufacturer chart.** None. Denon's [downloads page](https://www.denondj.com/downloads.html) lists the [LC6000 PRIME MIDI Specification v1.0](https://cdn.inmusicbrands.com/denondj/lc6000/LC6000-PRIME-MIDI-Specification-v1.0.pdf) and nothing comparable for any other PRIME unit.
- **Mixxx mapping.** None.
- **Other, non-primary:**
  - [whanake-music/denon-prime-4-analysis](https://github.com/whanake-music/denon-prime-4-analysis): third-party USB captures of the Prime 4 (SysEx layout, jog-display commands, a "send all positions" request), as summarized in #121.
  - A forum post says the SC Live 4 uses the same MIDI messages as the Prime 4 ([Engine DJ forum](https://community.enginedj.com/t/midi-specification-sc-live-4/51665)). Unverified.
- **Unverified for the SC6000:** whether it presents as USB-MIDI or HID in computer mode. #121 notes that its jog display is a separate USB device.

**Mixer**
- **Hardware:** the SC6000/SC6000M has none. The Prime 4/2/Go and SC Live have a full mixer.
- **Docs coverage:** no public MIDI numbers or VU values for any of them.

### 5. Numark Mixtrack Platinum FX / Pro FX

**Sources**
- **Manufacturer chart.** None found. The [Pro FX user guide](https://cdn.inmusicbrands.com/Numark/vAC9uYWEnT/mtprfx/MixTrackProFX-UserGuide-v1.2.pdf) is linked from Mixxx's page; I didn't find a MIDI table in public results. Unverified.
- **Mixxx mapping, Platinum FX:**
  - [`Numark Mixtrack Platinum FX.midi.xml`](https://github.com/mixxxdj/mixxx/blob/dc4bf99322bb9a4c59483d24c2c40d1df2d1b726/res/controllers/Numark%20Mixtrack%20Platinum%20FX.midi.xml)
  - [`Numark-Mixtrack-Platinum-FX-scripts.js`](https://github.com/mixxxdj/mixxx/blob/dc4bf99322bb9a4c59483d24c2c40d1df2d1b726/res/controllers/Numark-Mixtrack-Platinum-FX-scripts.js)
  - [manual page](https://github.com/mixxxdj/manual/blob/main/source/hardware/controllers/numark_mixtrack_platinum_fx.md), which says firmware 1.10 is required.
- **Mixxx mapping, Pro FX:**
  - [`Numark Mixtrack Pro FX.midi.xml`](https://github.com/mixxxdj/mixxx/blob/dc4bf99322bb9a4c59483d24c2c40d1df2d1b726/res/controllers/Numark%20Mixtrack%20Pro%20FX.midi.xml)
  - [`Numark-Mixtrack-Pro-FX-scripts.js`](https://github.com/mixxxdj/mixxx/blob/dc4bf99322bb9a4c59483d24c2c40d1df2d1b726/res/controllers/Numark-Mixtrack-Pro-FX-scripts.js)
- **Startup and shutdown messages.** Mixxx sends three things at startup and one at shutdown ([L155–156, L202–203, L244](https://github.com/mixxxdj/mixxx/blob/dc4bf99322bb9a4c59483d24c2c40d1df2d1b726/res/controllers/Numark-Mixtrack-Platinum-FX-scripts.js#L155-L156)):
  - a universal SysEx that exits demo mode;
  - the `00 20 7F` status request;
  - a fader-cut setting;
  - at shutdown, the `00 20 7F … 02` goodbye that #121 saw djay send the LC6000.

**Mixer**
- **Hardware:** yes. 2 faders, gain, 3-band EQ, filter, cue, crossfader and per-deck VU.
- **Docs coverage, via Mixxx only:**
  - Fader: CC 0x1C on the deck channel.
  - Crossfader: CC 0x08 on channel 16.
  - Pitch: 14-bit, CC 0x09/0x29.
- **VU:** out on CC 0x1F per deck channel; Mixxx scales it to about 0–90 ([L1636–1639](https://github.com/mixxxdj/mixxx/blob/dc4bf99322bb9a4c59483d24c2c40d1df2d1b726/res/controllers/Numark-Mixtrack-Platinum-FX-scripts.js#L1636-L1639)). The real LED thresholds are undocumented.

### 6. Hercules DJControl Inpulse 500 / 300

**Sources**
- **Manufacturer chart.** None found. DJUCED's ["Mapping and Manual" page](https://www.djuced.com/kb/hercules-djcontrol-inpulse-500/) describes functions, not MIDI numbers.
- **Mixxx mapping, Inpulse 500:**
  - [`Hercules_DJControl_Inpulse_500.midi.xml`](https://github.com/mixxxdj/mixxx/blob/dc4bf99322bb9a4c59483d24c2c40d1df2d1b726/res/controllers/Hercules_DJControl_Inpulse_500.midi.xml)
  - [`Hercules-DJControl-Inpulse-500-script.js`](https://github.com/mixxxdj/mixxx/blob/dc4bf99322bb9a4c59483d24c2c40d1df2d1b726/res/controllers/Hercules-DJControl-Inpulse-500-script.js)
  - [manual page](https://github.com/mixxxdj/manual/blob/main/source/hardware/controllers/hercules_djcontrol_inpulse_500.md)
- **Mixxx mapping, Inpulse 300:** [`Hercules_DJControl_Inpulse_300.midi.xml`](https://github.com/mixxxdj/mixxx/blob/dc4bf99322bb9a4c59483d24c2c40d1df2d1b726/res/controllers/Hercules_DJControl_Inpulse_300.midi.xml). Its [manual page](https://github.com/mixxxdj/manual/blob/main/source/hardware/controllers/hercules_djcontrol_inpulse_300.md) says FX-mode pads need firmware 1.72.
- **Jog resolution.** Mixxx uses 720 ticks per revolution for the Inpulse 500 ([L453](https://github.com/mixxxdj/mixxx/blob/dc4bf99322bb9a4c59483d24c2c40d1df2d1b726/res/controllers/Hercules-DJControl-Inpulse-500-script.js#L453)).

**Mixer**
- **Hardware:** yes.
- **Docs coverage, via Mixxx:**
  - Faders and pitch are 14-bit (Inpulse 500, deck A: volume CC 0x00/0x20, pitch CC 0x08/0x28, on channel 2).
  - Deck VU: out on CC 0x40 on channels 2 and 3 ([L166–173](https://github.com/mixxxdj/mixxx/blob/dc4bf99322bb9a4c59483d24c2c40d1df2d1b726/res/controllers/Hercules-DJControl-Inpulse-500-script.js#L166-L173)).
- **Hardware-driven parts:** DJUCED's manual says the master VU, master volume and headphone volume work in hardware, so they need no host.

### 7. DDJ-REV1 (REV5, REV7)

**Sources:** manufacturer charts, archived. There is no Mixxx mapping for any of the three.
- [REV1 list (2024-02-24)](https://web.archive.org/web/20240224053404/https://www.pioneerdj.com/-/media/pioneerdj/software-info/controller/ddj-rev1/ddj-rev1_midi_message_list_e1.pdf)
- [REV5 list (2025-06-23)](https://web.archive.org/web/20250623061926/https://www.pioneerdj.com/-/media/pioneerdj/software-info/controller/ddj-rev5/ddj-rev5_midi_message_list_e1.pdf)
- [REV7 list (2024-10-13)](https://web.archive.org/web/20241013145617/https://www.pioneerdj.com/-/media/pioneerdj/software-info/controller/ddj-rev7/ddj-rev7_midi_message_list_e1.pdf)

**Mixer**
- **Hardware:** yes.
- **Docs coverage:** the REV1 list gives 14-bit CCs in the same Pioneer layout as the FLX4: fader 0x13/0x33, trim 0x04/0x24, EQ 0x07/0x0B/0x0F, crossfader 0x1F/0x3F on channel 7. The REV5 list gives a channel level meter on CC 0x02 (page 3).
- **Pad colors:** the REV5 and REV7 lists say pads light in a "color number" from 1 to 127, with no table.

### 8. DDJ-1000 (DDJ-SX3)

**Sources:** manufacturer charts, archived. Mixxx maps only the older [DDJ-SX](https://github.com/mixxxdj/mixxx/blob/dc4bf99322bb9a4c59483d24c2c40d1df2d1b726/res/controllers/Pioneer%20DDJ-SX.midi.xml), not these two.
- [DDJ-1000 list (2025-08-27)](https://web.archive.org/web/20250827124612/https://www.pioneerdj.com/-/media/pioneerdj/software-info/controller/ddj-1000/ddj-1000_midi_message_list_e1.pdf)
- [DDJ-SX3 list (2024-05-18)](https://web.archive.org/web/20240518164243/https://www.pioneerdj.com/-/media/pioneerdj/software-info/controller/ddj-sx3/ddj-sx3_midi_message_list_e1.pdf)

**Mixer**
- **Hardware:** yes, 4 channels.
- **Docs coverage:** the DDJ-1000 list gives 14-bit CCs for every fader and knob. It marks the master level meter as not MIDI-controllable (page 3). Pads light in "color number 1–127" with no table.

### 9. DDJ-FLX6

**Sources**
- **Manufacturer chart.** [Archived list (2021-11-24)](https://web.archive.org/web/20211124100739/https://www.pioneerdj.com/-/media/pioneerdj/software-info/controller/ddj-flx6/ddj-flx6_midi_message_list_e1.pdf).
- **Mixxx mapping.** None.

**Mixer**
- **Hardware:** yes, 4 channels.
- **Docs coverage:** the list includes channel level meters on CC 0x02 for each of channels 1–4 (page 5) and the same jog encoding as the FLX4.

### 10. Traktor Kontrol S2 MK3 / S3

**Sources**
- **NI's MIDI-mode article** ([link](https://support.native-instruments.com/support/solutions/articles/69000880031-native-instruments-switching-your-controller-to-midi-mode)). No MIDI assignment published.
- **Mixxx mapping.** HID only: [`Traktor Kontrol S2 MK3.hid.xml`](https://github.com/mixxxdj/mixxx/blob/dc4bf99322bb9a4c59483d24c2c40d1df2d1b726/res/controllers/Traktor%20Kontrol%20S2%20MK3.hid.xml), [`Traktor Kontrol S3.hid.xml`](https://github.com/mixxxdj/mixxx/blob/dc4bf99322bb9a4c59483d24c2c40d1df2d1b726/res/controllers/Traktor%20Kontrol%20S3.hid.xml).

**Mixer**
- **Hardware:** yes. The S2 MK3 manual page lists VU meter LEDs.
- **Docs coverage:** no MIDI-mode numbers, so everything needs a capture.

## 5. Docs coverage for the top 3, per profile section

**How to read the tables.**
- **Coverage** is my estimate of how much of each section a draft can fill from public sources without hardware: High is about 80% or more, Medium about 40–80%, Low under 40%.
- **Still needs a capture** lists what only the hardware can settle.
- **Every profile also needs:**
  - the exact CoreMIDI port names for `device_hints` and `exclude_hints`, which no document gives;
  - an owner willing to capture. Owner availability is unknown for all three.

### 5.1 DDJ-400

Drafted from the FLX4 official list plus Mixxx's DDJ-400 mapping.

| Section | Coverage | What the sources give | Still needs a capture |
|---|---|---|---|
| Transport | High | Mixxx: play note 0x0B, cue 0x0C, sync, loop and beat-jump notes on the deck channel (1 = deck 1, 2 = deck 2). FLX4 list p.1 gives the same numbers. | That the 6 DDJ-400-only Mixxx inputs and the FLX4 numbers match this unit; whether BEAT SYNC sends on release, as the FLX4 does (FLX4 list p.5, footnote 3). |
| Pads | High (input), Medium (modes) | Pads on their own MIDI channels: 8 = deck 1, 9 = deck 1 + Shift, 10 = deck 2, 11 = deck 2 + Shift. Each pad mode uses a different note range (Mixxx `hotcue_1_activate` 0x97/0x00, [XML L1078](https://github.com/mixxxdj/mixxx/blob/dc4bf99322bb9a4c59483d24c2c40d1df2d1b726/res/controllers/Pioneer-DDJ-400.midi.xml#L1078); FLX4 list pp.3–5). | The DDJ-400's own pad-mode set (it has fewer modes than the FLX4; unverified which). |
| Jog | Medium–High | Platter top on CC 0x22 (vinyl mode on) or CC 0x23 (vinyl mode off), wheel side on CC 0x21, Shift + platter on CC 0x29, all relative offset-64 (0x41 and up = clockwise, 0x3F and down = counterclockwise; FLX4 list p.1). Touch is note 0x36, Shift-touch note 0x67 (Mixxx [XML L213–225](https://github.com/mixxxdj/mixxx/blob/dc4bf99322bb9a4c59483d24c2c40d1df2d1b726/res/controllers/Pioneer-DDJ-400.midi.xml#L213-L225)). Mixxx uses 720 ticks per turn ([script L506](https://github.com/mixxxdj/mixxx/blob/dc4bf99322bb9a4c59483d24c2c40d1df2d1b726/res/controllers/Pioneer-DDJ-400-script.js#L506)); that's Mixxx's tuning, not a spec. | Ticks per revolution; which CC the top sends with vinyl mode off; whether the vinyl on/off state needs a host message (the FLX4 list says vinyl mode can be changed only from the app, p.5 footnote 2). |
| Pitch | High | 14-bit tempo fader on CC 0x00/0x20 (Mixxx [XML L321](https://github.com/mixxxdj/mixxx/blob/dc4bf99322bb9a4c59483d24c2c40d1df2d1b726/res/controllers/Pioneer-DDJ-400.midi.xml#L321); FLX4 list p.2). | Direction (which end is +), the center detent value, and whether `invert` is needed. |
| LEDs | High | Button LEDs answer the same note as the button. Mixxx's 110 outputs are identical to the FLX4's. | Whether any value between 0 and 127 gives a dim level (for `leds.levels`, #194). |
| Colors | N/A (likely) | Pad outputs are on/off only (0x00/0x7F) in Mixxx and the FLX4 list, so the pads look single-color. | Confirm that the pads are single-color. If so, the profile needs a "no color table" mode (#197). |
| Layers | High | 2 decks, deck = MIDI channel 1/2, no deck switching. But pads live on channels 8–11, and the mixer, browse and FX sit on channel 7. | Nothing new. **Profile gap:** a profile can't yet put pads on a different channel from the deck's buttons (new #48 row, see section 6). |
| Mixer | High | Every fader and knob is a 14-bit pair (section 4). Filter on channel 7. VU on CC 0x02. | VU band thresholds on this unit; that the cue note is 0x54. |
| Handshake | Medium | No handshake is known to be required. Mixxx sends one position-query SysEx at start. | Whether the unit behaves without it. Whether the query is useful for pickup. |

### 5.2 DDJ-FLX4

The official list (Ver 1.0) is the primary source, with Mixxx as a cross-check.

| Section | Coverage | What the sources give | Still needs a capture |
|---|---|---|---|
| Transport | High | Every button with its note and channel, Shift variants included (list pp.1–2). BEAT SYNC sends on release (p.5, footnote 3). | Port names only. |
| Pads | High | Pad channels 8–11 as on the DDJ-400. All 8 modes and their note ranges (pp.3–5). | Nothing beyond the profile gap (pads on their own channel). |
| Jog | Medium–High | Same CCs and offset-64 encoding as the DDJ-400. The list says each value is the change since the previous message (p.1). Touch is note 0x36. | Ticks per revolution (not in the list; Mixxx uses 720). |
| Pitch | High | 14-bit CC 0x00/0x20 (p.2). | Direction. |
| LEDs | High | The list marks which controls accept MIDI-OUT, with OFF 0x00 and ON 0x7F. The FX ON/OFF button blinks on note on and lights steadily on note off (p.5, footnote 4). | Dim levels. |
| Colors | N/A (likely) | Single-color pads per the list (on/off only). | Confirm. |
| Layers | High | 2 decks on channels 1/2; pads on channels 8–11; mixer on channel 7. | As for the DDJ-400. |
| Mixer | High | Every fader and knob is a 14-bit pair, and VU has 5 documented bands (p.2). | None beyond port names. |
| Handshake | Low–Medium | The list documents no SysEx. Mixxx sends a SysEx every 200 ms (a position query its authors say doubles as a keep-alive, found with Wireshark; [script L174–175, L315–318](https://github.com/mixxxdj/mixxx/blob/dc4bf99322bb9a4c59483d24c2c40d1df2d1b726/res/controllers/Pioneer-DDJ-FLX4-script.js#L174-L175)). | **What fails without the keep-alive. Unknown, and it may need #199.** |

### 5.3 Denon DJ MC7000

The sources are Mixxx's MC7000 mapping, cross-checked against Denon's official MCX8000 list (sibling proxy).

| Section | Coverage | What the sources give | Still needs a capture |
|---|---|---|---|
| Transport | High | Play note 0x00 and cue note 0x01, one channel per deck: 1–4 = decks 1–4 (Mixxx XML; MCX8000 list p.1). The MCX8000 list also gives the Shift variants (for example Shift + Play = note 0x04). | That the MC7000 matches the MCX8000 for controls Mixxx doesn't map. |
| Pads | High | Pads on channels 5–8 (0x94 + deck index), with pad-mode buttons on the same channel (Mixxx XML). The MCX8000 list gives pads 1–8 as notes 0x14–0x1B and Shift + pad as 0x1C–0x23, with no per-mode note sets (p.1). | That the MC7000 uses one note set across modes, as the MCX8000 does. |
| Jog | Medium | Relative CC 0x06 on the deck channel, two's-complement-style (small values forward, values near 128 backward; [script L722–727](https://github.com/mixxxdj/mixxx/blob/dc4bf99322bb9a4c59483d24c2c40d1df2d1b726/res/controllers/Denon-MC7000-scripts.js#L722-L727)). Touch is note 0x06. Mixxx uses 894 ticks per turn ([L133](https://github.com/mixxxdj/mixxx/blob/dc4bf99322bb9a4c59483d24c2c40d1df2d1b726/res/controllers/Denon-MC7000-scripts.js#L133)). The MIDI send interval set in hardware settings mode may also affect it (Denon spec p.3). | Ticks per revolution and the edge versus top behavior. |
| Pitch | Medium | 14-bit pitch on CC 0x09 and **CC 0x77** (not the usual n + 32). **The sources disagree on which is the MSB.** The MCX8000 list labels 0x09 as the LSB and 0x77 as the MSB (p.1), but Mixxx's MC7000 script treats 0x09 as the MSB ( Mixxx [XML L573](https://github.com/mixxxdj/mixxx/blob/dc4bf99322bb9a4c59483d24c2c40d1df2d1b726/res/controllers/Denon-MC7000.midi.xml#L573), [script L792–800](https://github.com/mixxxdj/mixxx/blob/dc4bf99322bb9a4c59483d24c2c40d1df2d1b726/res/controllers/Denon-MC7000-scripts.js#L792-L800)). Mixxx inverts it. | Which CC is the MSB; the direction. |
| LEDs | Medium | Button LEDs on the same notes. Platter ring LEDs are driven by Mixxx's script. | Dim levels; platter ring addressing. |
| Colors | Medium | Pad color byte = 2 bits each of R, G and B, plus 1, per Mixxx ([L176–178](https://github.com/mixxxdj/mixxx/blob/dc4bf99322bb9a4c59483d24c2c40d1df2d1b726/res/controllers/Denon-MC7000-scripts.js#L176-L178)). That fits the MCX8000's 64-velocity table, where 1 is off (p.3). The swatches there are images, so the RGB for each velocity is still inferred. Close to our provisional LC6000 rgb222 table, but offset by one. | The RGB for each velocity (#197). |
| Layers | High | One MIDI channel per deck, 1–4, like the LC6000's layers. | Whether the DECK 1/3 and 2/4 buttons send a layer note, like the LC6000's `layer_note`. |
| Mixer | Medium–High | 7-bit CCs for trim, EQ, filter and fader; VU on CC 0x1F with 10 documented bands (MCX8000 p.4, matching Mixxx's MC7000 peak of 0x76). | That the MC7000's meters have the same LED count and bands as the MCX8000's. |
| Handshake | Medium | Mixxx sends the `00 20 7F` status SysEx at startup ([L223–224](https://github.com/mixxxdj/mixxx/blob/dc4bf99322bb9a4c59483d24c2c40d1df2d1b726/res/controllers/Denon-MC7000-scripts.js#L223-L224)): the same family as the LC6000's Serato hello (#121). | Whether it's required, and whether the LC6000's full hello also applies. Probably needs #199. |

### Gaps the docs usually miss, across all candidates

- **LED color value tables.**
  - Pioneer's 4-channel and REV lists say "color number 1–127" but print no table.
  - Denon documents velocity tables for the LC6000 and the MCX8000, but in both the color swatches are images, not RGB values. That may be why our LC6000 table is still provisional.
  - Hercules' and the MC7000's color bytes are known only from Mixxx.
- **14-bit pairs.**
  - Pioneer lists them explicitly, with MSB n and LSB n + 32.
  - The MC7000/MCX8000 pitch pair breaks the n + 32 rule (CC 0x09 and 0x77). The official MCX8000 list and Mixxx disagree on which CC is the MSB.
- **Jog encoding.**
  - Pioneer documents the encoding (offset-64) but not the resolution.
  - No source gives ticks per revolution. Mixxx's values (720, 894, 1024) are its own tuning.
  - Touch notes are documented by Pioneer and only inferable elsewhere.
- **Host-mode and SysEx handshakes.**
  - No manufacturer list documents one.
  - All three that Mixxx uses (the FLX4 keep-alive, the DDJ-400 position query, the inMusic `00 20 7F` status message) are community-found. The FLX4's was found with Wireshark.
- **Screens and displays.**
  - Undocumented everywhere: the DDJ-1000 jog displays, the Mixtrack Platinum FX jog LCDs (Mixxx drives a spinner with plain CCs), and the PRIME jog displays (only third-party analysis exists).
  - Denon's LC6000 spec states that the wheel display needs SysEx and leaves it out (p.6).

## 6. Recommendation: ship the DDJ-400 first

**Recommendation.** After [#48](https://github.com/ericdahl-dev/deckbridge/issues/48), ship the **Pioneer DDJ-400** as the first new profile ([#202](https://github.com/ericdahl-dev/deckbridge/issues/202)). Draft it from the FLX4's official MIDI list plus Mixxx's DDJ-400 mapping. Ship the **DDJ-FLX4** right after it from the same draft, if Syndicate's own FLX4 support turns out to be partial.

**Why**
1. **It's the biggest gap Syndicate leaves.** Pioneer calls the DDJ-400 its entry-level standard. It sold for years before the FLX4 replaced it, and Syndicate's built-in mapping doesn't light it (section 2: LED feedback only in the FLX4/FLX10 presets).
2. **It has the best docs of any unit Syndicate doesn't serve.** Its own chart is missing, but it shares about 97% of its inputs and 100% of its LED outputs with the FLX4 in Mixxx. The FLX4's official list covers transport, pads, jog encoding, the 14-bit pitch, the full mixer and the VU scale. Of the remaining candidates, the MC7000 rests on Mixxx plus a sibling's list, and the PRIME units on nothing public.
3. **Few of the open profile-key issues apply,** though it needs two or three new #48 rows (see the matrix). Relative jog ([#204](https://github.com/ericdahl-dev/deckbridge/issues/204)) and offset-64 encoding ([#193](https://github.com/ericdahl-dev/deckbridge/issues/193)) are merged. The pitch is already a 14-bit pair (no [#195](https://github.com/ericdahl-dev/deckbridge/issues/195)). It has 8 pads (no [#196](https://github.com/ericdahl-dev/deckbridge/issues/196)). Its pads are likely single-color, so [#197](https://github.com/ericdahl-dev/deckbridge/issues/197) reduces to "no color". Its pad modes have separate buttons (no [#198](https://github.com/ericdahl-dev/deckbridge/issues/198)). It needs no SysEx as far as Mixxx shows (no [#199](https://github.com/ericdahl-dev/deckbridge/issues/199)).
4. **The FLX4 then comes almost free.** It needs the same profile plus a check on the keep-alive.

**Fit matrix for the top 3.** "Reuses" means a merged profile key; "Needs" means an open issue or a new #48 row.

| Needs / reuses | DDJ-400 | DDJ-FLX4 | MC7000 |
|---|---|---|---|
| #193 encoder format | reuses `offset_64` | reuses `offset_64` | reuses `twos_complement` |
| #204 relative jog | reuses | reuses | reuses |
| #195 7/14-bit pitch | no | no | no (but the LSB isn't n + 32; profile already takes both CCs) |
| #196 pad count | no (8) | no (8) | no (8) |
| #197 color table | "no color" mode | "no color" mode | yes (rgb222 + 1) |
| #198 cycling pad mode | no | no | no |
| #199 SysEx | probably not | **maybe** (keep-alive) | probably (status hello) |
| **New #48 row:** pads on a channel other than the deck's | **yes** | **yes** | **yes** |
| **New #48 row:** a different pad note set per pad mode | **yes** | **yes** | no (one set, per the MCX8000 list) |
| **New #48 row:** Shift handled in hardware (shifted controls send their own notes) | **yes** | **yes** | **yes** (per the MCX8000 list) |
| #207 mixer | **yes** | **yes** | **yes** |

**New #48 rows.** I checked these against `Mapping.swift` on `origin/main`. Today a profile has one MIDI channel per layer for everything, a single `notes.pads` list of 8 notes, and a Shift button whose combinations the app works out itself. The LC6000 spec lists Shift only as a plain note (26), with no shifted variants.
- **Pad channel.** All three put pads on MIDI channels separate from the deck's buttons: Pioneer uses 8–11, split by deck and by Shift; the MC7000 uses 5–8.
- **Pad notes per mode (Pioneer).** Each pad mode sends its own note range (FLX4 list pp.3–5), so one `pads` list can't cover them.
- **Shift in hardware.** Pioneer units send a different note, and for pads a different channel, when Shift is held. The SHIFT button also sends its own note (FLX4 list p.1). The MCX8000 list shows the same for inMusic (for example Shift + Play = note 0x04). App-side Shift combinations will never see the base note, so the profile needs to name the shifted notes.

None of these has an issue yet.

### What this means for #207 (mixer)

Every all-in-one candidate in the top 10 sends its mixer as MIDI for the software to mix (sections 4 and 5). That covers the DDJ-400/FLX4, MC7000, Mixtracks, Inpulses and REV/1000/FLX6. With the DDJ-400 bridged but no mixer section, DeckBridge would not pass on its channel faders, EQ, trim or filter.

There is a partial workaround. Syndicate's user mapping takes absolute CC 0–119 ([Syndicate User Guide 0.3.7, section 13.9](https://untitledaudiosyndicate.com/user-guide/index.html#c13-9)), so a user can map the mixer's faders and knobs inside Syndicate, but only at 7 bits (the MSB of each 14-bit pair, since CC pairs aren't supported), with no soft takeover, and with no VU meters on the controller (no generic LED feedback). Whether Syndicate can open the MIDI port while DeckBridge also has it open is still unverified.

So the workaround gives a usable but coarse mixer with dark meters. **#207 stays on the critical path for a good DDJ-400 experience**: it should ship with or soon after #202. It's not a hard blocker if the 7-bit user-mapped mixer is acceptable for a first release.

The only candidates that could ship decks-only are the SC6000/SC6000M (no mixer). They have no public MIDI docs and are unverified as USB-MIDI. If #207 must slip, the fallback is to bridge an SC6000 decks-only from an owner's full capture, at the cost of doing it with no docs.

On the plus side, the Pioneer docs make #207's controller side easy to draft. Every mixer control is a documented 14-bit pair, and the VU scale is published (FLX4 list p.2). That makes the DDJ-400/FLX4 a good test case for #207's pickup and VU rate limiting.

## 7. Risks and open points

- **The Syndicate claim is now sourced** ([Syndicate User Guide 0.3.7, section 13.9](https://untitledaudiosyndicate.com/user-guide/index.html#c13-9)): LED feedback only in the FLX4/FLX10 presets; no 14-bit CC pairs or relative CC in generic mapping.
- **A DDJ-400 owner can load Syndicate's FLX4 preset by hand.** The preset is chosen in CHOOSE PRESET, not matched by name (section 2), and the DDJ-400 and FLX4 share 193 of 199 inputs and all LED outputs in Mixxx. So the FLX4 preset may already run a DDJ-400 with lights. Ask a DDJ-400 owner to try it before building: if it works, the DDJ-400's gap is small and the ranking should move to a controller with no preset (MC7000 or a Mixtrack).
- **No DDJ-400 manufacturer chart.** The draft relies on FLX4 equivalence and on Mixxx. The 6 DDJ-400-only inputs in Mixxx (note 0x47 on channels 1 and 2, notes 0x11 and 0x14 on channel 5, and CC 0x0D/0x2D on channel 7) need a capture to place.
- **The FLX4 keep-alive is unexplained.** Mixxx sends it every 200 ms, but nobody has documented what fails without it.
- **#207 shapes the first profile.** Without it, the mixer is only user-mappable in Syndicate at 7 bits with dark meters (section 6).
- **The MC7000 pitch MSB is disputed.** The official MCX8000 list and Mixxx disagree on which CC is the MSB, so a capture must settle it.
- **The archived Pioneer PDFs aren't live.** The originals now redirect to AlphaTheta's support site, which refused scripted fetches. The archived copies are faithful, but Pioneer may have newer versions there.
- **The capture owner is unknown.** #202 needs an owner's capture, and none has been identified for any candidate.


## 8. 14-bit coverage (#414)

The user's priority (2026-11-17): target controllers with 14-bit controls first, since Syndicate's own MIDI mapping can't
use 14-bit CC pairs (section 2; ADR-0010). For each controller, which of seven controls send an MSB/LSB pair.

**Method.** For controllers with a Mixxx mapping at `dc4bf99`, each control was found in the mapping and checked for
Mixxx's `fourteen-bit-msb`/`-lsb` options, an MSB/LSB CC pair, or script inputs named MSB and LSB. Each cell links the
line it rests on, and every cell was checked by reading that line. Rows with "(list)" rest on the manufacturer's MIDI
list as already cited in section 4. **14** is a 14-bit pair, **7** a single 7-bit CC, **rel** a relative jog (7-bit
ticks), "—" no such control. "…" means the other EQ bands follow the same pattern. The count is 14-bit controls out of
the seven; a relative jog doesn't count, the LC6000's absolute 14-bit jog does.

| Controller | Pitch | Jog | Channel fader | Crossfader | EQ | Filter | Trim | 14-bit of 7 |
|---|---|---|---|---|---|---|---|---|
| Denon LC6000 PRIME (today's profile) | **14** CC 8/40 (hardware, README) | **14 absolute** CC 17/49 (hardware, README) | — | — | — | — | — | 2 (no mixer) |
| Pioneer DDJ-400 | **14** [0x00/0x20](https://github.com/mixxxdj/mixxx/blob/dc4bf99322bb9a4c59483d24c2c40d1df2d1b726/res/controllers/Pioneer-DDJ-400.midi.xml#L308) | rel [0x22](https://github.com/mixxxdj/mixxx/blob/dc4bf99322bb9a4c59483d24c2c40d1df2d1b726/res/controllers/Pioneer-DDJ-400.midi.xml#L178) | **14** [0x13/0x33](https://github.com/mixxxdj/mixxx/blob/dc4bf99322bb9a4c59483d24c2c40d1df2d1b726/res/controllers/Pioneer-DDJ-400.midi.xml#L645) | **14** [0x1F/0x3F, ch 7](https://github.com/mixxxdj/mixxx/blob/dc4bf99322bb9a4c59483d24c2c40d1df2d1b726/res/controllers/Pioneer-DDJ-400.midi.xml#L624) | **14** [0x07/0x27 …](https://github.com/mixxxdj/mixxx/blob/dc4bf99322bb9a4c59483d24c2c40d1df2d1b726/res/controllers/Pioneer-DDJ-400.midi.xml#L749) | **14** [0x17/0x37, ch 7](https://github.com/mixxxdj/mixxx/blob/dc4bf99322bb9a4c59483d24c2c40d1df2d1b726/res/controllers/Pioneer-DDJ-400.midi.xml#L920) | **14** [0x04/0x24](https://github.com/mixxxdj/mixxx/blob/dc4bf99322bb9a4c59483d24c2c40d1df2d1b726/res/controllers/Pioneer-DDJ-400.midi.xml#L707) | 6 |
| Pioneer DDJ-FLX4 | **14** FLX4 list p.2; [Mixxx](https://github.com/mixxxdj/mixxx/blob/dc4bf99322bb9a4c59483d24c2c40d1df2d1b726/res/controllers/Pioneer-DDJ-FLX4.midi.xml#L318) | rel, FLX4 list p.1 | **14** p.2 | **14** p.2 (ch 7) | **14** p.2 | **14** p.2 (ch 7) | **14** p.2 | 6 |
| Pioneer DDJ-1000 | **14** (list, section 4.8) | not checked | **14** (list) | **14** (list) | **14** (list) | **14** (list) | **14** (list) | 6 |
| Pioneer DDJ-SX | **14** [0x00/0x20](https://github.com/mixxxdj/mixxx/blob/dc4bf99322bb9a4c59483d24c2c40d1df2d1b726/res/controllers/Pioneer%20DDJ-SX.midi.xml#L467) | rel [script](https://github.com/mixxxdj/mixxx/blob/dc4bf99322bb9a4c59483d24c2c40d1df2d1b726/res/controllers/Pioneer%20DDJ-SX.midi.xml#L577) | **14** [0x13/0x33](https://github.com/mixxxdj/mixxx/blob/dc4bf99322bb9a4c59483d24c2c40d1df2d1b726/res/controllers/Pioneer%20DDJ-SX.midi.xml#L207) | **14** [0x1F/0x3F, ch 7](https://github.com/mixxxdj/mixxx/blob/dc4bf99322bb9a4c59483d24c2c40d1df2d1b726/res/controllers/Pioneer%20DDJ-SX.midi.xml#L39) | **14** [0x0F/0x2F …](https://github.com/mixxxdj/mixxx/blob/dc4bf99322bb9a4c59483d24c2c40d1df2d1b726/res/controllers/Pioneer%20DDJ-SX.midi.xml#L247) | **14** [0x17/0x37](https://github.com/mixxxdj/mixxx/blob/dc4bf99322bb9a4c59483d24c2c40d1df2d1b726/res/controllers/Pioneer%20DDJ-SX.midi.xml#L227) | **14** [0x04/0x24](https://github.com/mixxxdj/mixxx/blob/dc4bf99322bb9a4c59483d24c2c40d1df2d1b726/res/controllers/Pioneer%20DDJ-SX.midi.xml#L307) | 6 |
| Pioneer DDJ-SB3 | **14** [0x00/0x20](https://github.com/mixxxdj/mixxx/blob/dc4bf99322bb9a4c59483d24c2c40d1df2d1b726/res/controllers/Pioneer-DDJ-SB3.midi.xml#L578) | rel [script](https://github.com/mixxxdj/mixxx/blob/dc4bf99322bb9a4c59483d24c2c40d1df2d1b726/res/controllers/Pioneer-DDJ-SB3.midi.xml#L258) | **14** [0x13/0x33](https://github.com/mixxxdj/mixxx/blob/dc4bf99322bb9a4c59483d24c2c40d1df2d1b726/res/controllers/Pioneer-DDJ-SB3.midi.xml#L1018) | **14** [Mixxx 14-bit](https://github.com/mixxxdj/mixxx/blob/dc4bf99322bb9a4c59483d24c2c40d1df2d1b726/res/controllers/Pioneer-DDJ-SB3.midi.xml#L2198) | **14** [0x07/0x27 …](https://github.com/mixxxdj/mixxx/blob/dc4bf99322bb9a4c59483d24c2c40d1df2d1b726/res/controllers/Pioneer-DDJ-SB3.midi.xml#L1618) | **14** [0x17/0x37](https://github.com/mixxxdj/mixxx/blob/dc4bf99322bb9a4c59483d24c2c40d1df2d1b726/res/controllers/Pioneer-DDJ-SB3.midi.xml#L1178) | **14** [0x04/0x24](https://github.com/mixxxdj/mixxx/blob/dc4bf99322bb9a4c59483d24c2c40d1df2d1b726/res/controllers/Pioneer-DDJ-SB3.midi.xml#L1098) | 6 |
| Roland DJ-505 | **14** [0x09/0x3B](https://github.com/mixxxdj/mixxx/blob/dc4bf99322bb9a4c59483d24c2c40d1df2d1b726/res/controllers/Roland_DJ-505.midi.xml#L78) | rel [script](https://github.com/mixxxdj/mixxx/blob/dc4bf99322bb9a4c59483d24c2c40d1df2d1b726/res/controllers/Roland_DJ-505.midi.xml#L524) | **14** [0x1C/0x3A](https://github.com/mixxxdj/mixxx/blob/dc4bf99322bb9a4c59483d24c2c40d1df2d1b726/res/controllers/Roland_DJ-505.midi.xml#L705) | **14** [0x08/0x58, ch 16](https://github.com/mixxxdj/mixxx/blob/dc4bf99322bb9a4c59483d24c2c40d1df2d1b726/res/controllers/Roland_DJ-505.midi.xml#L3437) | **14** [0x17/0x37 …](https://github.com/mixxxdj/mixxx/blob/dc4bf99322bb9a4c59483d24c2c40d1df2d1b726/res/controllers/Roland_DJ-505.midi.xml#L575) | 7 [0x1A](https://github.com/mixxxdj/mixxx/blob/dc4bf99322bb9a4c59483d24c2c40d1df2d1b726/res/controllers/Roland_DJ-505.midi.xml#L635) | **14** [0x16 MSB/LSB](https://github.com/mixxxdj/mixxx/blob/dc4bf99322bb9a4c59483d24c2c40d1df2d1b726/res/controllers/Roland_DJ-505.midi.xml#L555) | 5 |
| Pioneer DDJ-REV1 | not stated | not checked | **14** (list, section 4.7) | **14** (list, ch 7) | **14** (list) | not stated | **14** (list) | ≥4 |
| Hercules Inpulse 500 | **14** [0x08/0x28, ch 2](https://github.com/mixxxdj/mixxx/blob/dc4bf99322bb9a4c59483d24c2c40d1df2d1b726/res/controllers/Hercules_DJControl_Inpulse_500.midi.xml#L3034) | rel [0x09, ch 2](https://github.com/mixxxdj/mixxx/blob/dc4bf99322bb9a4c59483d24c2c40d1df2d1b726/res/controllers/Hercules_DJControl_Inpulse_500.midi.xml#L3102) | **14** [0x00/0x20](https://github.com/mixxxdj/mixxx/blob/dc4bf99322bb9a4c59483d24c2c40d1df2d1b726/res/controllers/Hercules_DJControl_Inpulse_500.midi.xml#L2896) | 7 [0x00](https://github.com/mixxxdj/mixxx/blob/dc4bf99322bb9a4c59483d24c2c40d1df2d1b726/res/controllers/Hercules_DJControl_Inpulse_500.midi.xml#L2861) | **14** [0x02/0x22 …](https://github.com/mixxxdj/mixxx/blob/dc4bf99322bb9a4c59483d24c2c40d1df2d1b726/res/controllers/Hercules_DJControl_Inpulse_500.midi.xml#L2939) | 7 [0x01](https://github.com/mixxxdj/mixxx/blob/dc4bf99322bb9a4c59483d24c2c40d1df2d1b726/res/controllers/Hercules_DJControl_Inpulse_500.midi.xml#L3023) | **14** [0x05/0x25](https://github.com/mixxxdj/mixxx/blob/dc4bf99322bb9a4c59483d24c2c40d1df2d1b726/res/controllers/Hercules_DJControl_Inpulse_500.midi.xml#L3002) | 4 |
| Denon MC7000 | **14** [0x09](https://github.com/mixxxdj/mixxx/blob/dc4bf99322bb9a4c59483d24c2c40d1df2d1b726/res/controllers/Denon-MC7000.midi.xml#L611) + [0x77](https://github.com/mixxxdj/mixxx/blob/dc4bf99322bb9a4c59483d24c2c40d1df2d1b726/res/controllers/Denon-MC7000.midi.xml#L571) (MSB disputed, section 5.3) | rel [0x06](https://github.com/mixxxdj/mixxx/blob/dc4bf99322bb9a4c59483d24c2c40d1df2d1b726/res/controllers/Denon-MC7000.midi.xml#L1135) | 7 [0x1C](https://github.com/mixxxdj/mixxx/blob/dc4bf99322bb9a4c59483d24c2c40d1df2d1b726/res/controllers/Denon-MC7000.midi.xml#L1377) | 7 [0x08, ch 16](https://github.com/mixxxdj/mixxx/blob/dc4bf99322bb9a4c59483d24c2c40d1df2d1b726/res/controllers/Denon-MC7000.midi.xml#L1420) | 7 [0x17 …](https://github.com/mixxxdj/mixxx/blob/dc4bf99322bb9a4c59483d24c2c40d1df2d1b726/res/controllers/Denon-MC7000.midi.xml#L1176) | 7 [0x1A](https://github.com/mixxxdj/mixxx/blob/dc4bf99322bb9a4c59483d24c2c40d1df2d1b726/res/controllers/Denon-MC7000.midi.xml#L1296) | 7 [0x16](https://github.com/mixxxdj/mixxx/blob/dc4bf99322bb9a4c59483d24c2c40d1df2d1b726/res/controllers/Denon-MC7000.midi.xml#L1337) | 1 |
| Numark Mixtrack Platinum FX | **14** [0x09/0x29](https://github.com/mixxxdj/mixxx/blob/dc4bf99322bb9a4c59483d24c2c40d1df2d1b726/res/controllers/Numark%20Mixtrack%20Platinum%20FX.midi.xml#L1260) | rel [script](https://github.com/mixxxdj/mixxx/blob/dc4bf99322bb9a4c59483d24c2c40d1df2d1b726/res/controllers/Numark%20Mixtrack%20Platinum%20FX.midi.xml#L936) | 7 [0x1C](https://github.com/mixxxdj/mixxx/blob/dc4bf99322bb9a4c59483d24c2c40d1df2d1b726/res/controllers/Numark%20Mixtrack%20Platinum%20FX.midi.xml#L2574) | 7 [0x08, ch 2](https://github.com/mixxxdj/mixxx/blob/dc4bf99322bb9a4c59483d24c2c40d1df2d1b726/res/controllers/Numark%20Mixtrack%20Platinum%20FX.midi.xml#L1206) | 7 [0x17 …](https://github.com/mixxxdj/mixxx/blob/dc4bf99322bb9a4c59483d24c2c40d1df2d1b726/res/controllers/Numark%20Mixtrack%20Platinum%20FX.midi.xml#L1998) | 7 [0x1A](https://github.com/mixxxdj/mixxx/blob/dc4bf99322bb9a4c59483d24c2c40d1df2d1b726/res/controllers/Numark%20Mixtrack%20Platinum%20FX.midi.xml#L2322) | 7 [0x16](https://github.com/mixxxdj/mixxx/blob/dc4bf99322bb9a4c59483d24c2c40d1df2d1b726/res/controllers/Numark%20Mixtrack%20Platinum%20FX.midi.xml#L1890) | 1 |
| Numark Mixtrack Pro FX | **14** [0x09/0x29](https://github.com/mixxxdj/mixxx/blob/dc4bf99322bb9a4c59483d24c2c40d1df2d1b726/res/controllers/Numark%20Mixtrack%20Pro%20FX.midi.xml#L162) | rel [script](https://github.com/mixxxdj/mixxx/blob/dc4bf99322bb9a4c59483d24c2c40d1df2d1b726/res/controllers/Numark%20Mixtrack%20Pro%20FX.midi.xml#L1581) | 7 [0x1C](https://github.com/mixxxdj/mixxx/blob/dc4bf99322bb9a4c59483d24c2c40d1df2d1b726/res/controllers/Numark%20Mixtrack%20Pro%20FX.midi.xml#L143) | 7 [0x08, ch 16](https://github.com/mixxxdj/mixxx/blob/dc4bf99322bb9a4c59483d24c2c40d1df2d1b726/res/controllers/Numark%20Mixtrack%20Pro%20FX.midi.xml#L29) | 7 [0x17 …](https://github.com/mixxxdj/mixxx/blob/dc4bf99322bb9a4c59483d24c2c40d1df2d1b726/res/controllers/Numark%20Mixtrack%20Pro%20FX.midi.xml#L69) | 7 [0x1A](https://github.com/mixxxdj/mixxx/blob/dc4bf99322bb9a4c59483d24c2c40d1df2d1b726/res/controllers/Numark%20Mixtrack%20Pro%20FX.midi.xml#L124) | not checked | 1 |
| Denon SC6000 / PRIME 2 / PRIME 4 (MIDI mode) | unknown | unknown | unknown | unknown | unknown | unknown | unknown | ? (no public MIDI list; #272) |
| Rane (ONE, SEVENTY…) | not found | not found | not found | not found | not found | not found | not found | ? (no public MIDI list found) |
| NI Traktor S2/S4 MK3 | HID | HID | HID | HID | HID | HID | HID | n/a (HID, not MIDI) |

**What this shows**
- **Pioneer is 14-bit throughout.** Every fader and knob on the DDJ-400, FLX4, SX, SB3 and 1000 is a pair, MSB n and LSB
  n + 32. The crossfader and the filter sit on channel 7.
- **The Roland DJ-505** is 14-bit except its filter, but its pairs don't follow n + 32 (tempo 0x09/0x3B, fader
  0x1C/0x3A), and its crossfader is on channel 16. Profiles already name `msb_cc` and `lsb_cc` separately, so that
  needs no new key.
- **The Hercules Inpulse 500** pairs its pitch, channel faders, EQ and trim; its crossfader and filter are 7-bit.
- **The Denon MC7000 and the Numark Mixtrack FX pair** pair only the pitch fader. Their mixers are 7-bit.
- **Every jog except the LC6000's is relative.** DeckBridge handles both (#204).
- **No public MIDI list** was found for the PRIME units in MIDI mode or for Rane. NI's S2/S4 MK3 are HID devices,
  out of scope for a MIDI profile.

### Recommended v1.2 profile order

The primary key is 14-bit coverage. Popularity comes second: section 3's ranking where a unit is in it, and otherwise
unsourced, so it's listed last within a tie.

1. **Pioneer DDJ-400** (6 of 7). It's section 3's #1, and the drafts from #280 already exist.
2. **Pioneer DDJ-FLX4** (6). The same draft and messages; Syndicate's own FLX4 preset can't read its 14-bit pairs.
3. **Pioneer DDJ-1000** (6). It has an official list; 4 decks.
4. **Pioneer DDJ-SB3** and **DDJ-SX** (6). Mixxx mappings exist; they aren't in section 3's top 10.
5. **Roland DJ-505** (5). A Mixxx mapping exists; not in the top 10.
6. **Hercules Inpulse 500** (4). Section 3's #6.
7. **Pioneer DDJ-REV1** (at least 4). Section 3's #7.
8. **Denon MC7000** (1) and **Numark Mixtrack Platinum FX / Pro FX** (1). Section 3's #3 and #5, but only their
   pitch fader is 14-bit.

The PRIME units and Rane wait for a public list or an owner's capture (#272).

### The DDJ-400/FLX4 drafts and the new keys

- **The #280 drafts** already set the 14-bit pitch fader and the 14-bit channel fader, trim and EQ high/mid/low in
  `mixer`, with `bits: 14` (`docs/research/ddj/`). They leave out the 14-bit **filter** and **crossfader**, for the
  two reasons below.
- **14-bit mixer controls need no new key in general.** `mixer.<control>` takes `bits` 7 or 14 with `msb_cc` and
  `lsb_cc`, including pairs that aren't n + 32 (#207).
- **New keys still needed:**
  - **#368, a channel per mixer control:** the Pioneer filter and crossfader are on channel 7, and the Roland
    crossfader on channel 16, as are the MC7000's and the Mixtrack Pro FX's (the Platinum FX's is on channel 2), not
    the deck's channel.
  - **#369, a crossfader:** `mixer` has none, and every 14-bit unit above has a 14-bit crossfader.
- **Already supported:** a relative jog (#204) and the LC6000's absolute 14-bit jog.

## Sources

- [Syndicate User Guide 0.3.7, section 13.9](https://untitledaudiosyndicate.com/user-guide/index.html#c13-9): what Syndicate's MIDI mapping supports; build 0.3.7, updated Nov 14, 2026.

**Project**
- [README.md](../../README.md), line 5: the Syndicate support claim.
- Issues: [#48](https://github.com/ericdahl-dev/deckbridge/issues/48), [#121](https://github.com/ericdahl-dev/deckbridge/issues/121), [#184](https://github.com/ericdahl-dev/deckbridge/issues/184), [#191](https://github.com/ericdahl-dev/deckbridge/issues/191), [#193](https://github.com/ericdahl-dev/deckbridge/issues/193), [#194](https://github.com/ericdahl-dev/deckbridge/issues/194), [#195](https://github.com/ericdahl-dev/deckbridge/issues/195), [#196](https://github.com/ericdahl-dev/deckbridge/issues/196), [#197](https://github.com/ericdahl-dev/deckbridge/issues/197), [#198](https://github.com/ericdahl-dev/deckbridge/issues/198), [#199](https://github.com/ericdahl-dev/deckbridge/issues/199), [#202](https://github.com/ericdahl-dev/deckbridge/issues/202), [#204](https://github.com/ericdahl-dev/deckbridge/issues/204), [#207](https://github.com/ericdahl-dev/deckbridge/issues/207).

**Syndicate**
- [untitledaudiosyndicate.com](https://untitledaudiosyndicate.com)
- [/syndicate](https://untitledaudiosyndicate.com/syndicate)
- [/docs](https://untitledaudiosyndicate.com/docs): no readable content without a browser session.

**Pioneer DJ / AlphaTheta**
- [DDJ-FLX4 launch news (2022-11-08, German)](https://www.pioneerdj.com/de/news/2022/ddj-flx4-2-channel-dj-controller-for-multiple-dj-applications/)
- [DDJ-FLX4 officially supports djay](https://www.pioneerdj.com/en/news/2023/ddj-flx4-officially-supports-djay)
- [DDJ-FLX2 and DDJ-FLX4 support Traktor Play](https://www.pioneerdj.com/ja/news/2025/ddj-flx2-and-ddj-flx4-support-traktor-play/)
- [DDJ-FLX4 product page](https://www.pioneerdj.com/en/product/dj-controllers/ddj-flx4/)
- MIDI message lists (archived copies of `pioneerdj.com/-/media/pioneerdj/software-info/controller/<model>/<model>_midi_message_list_e1.pdf`):
  - [DDJ-FLX4](https://web.archive.org/web/20250805162346/https://www.pioneerdj.com/-/media/pioneerdj/software-info/controller/ddj-flx4/ddj-flx4_midi_message_list_e1.pdf)
  - [DDJ-FLX6](https://web.archive.org/web/20211124100739/https://www.pioneerdj.com/-/media/pioneerdj/software-info/controller/ddj-flx6/ddj-flx6_midi_message_list_e1.pdf)
  - [DDJ-FLX10](https://web.archive.org/web/20240227211936/https://www.pioneerdj.com/-/media/pioneerdj/software-info/controller/ddj-flx10/ddj-flx10_midi_message_list_e1.pdf): the archived copy is truncated at 1 MiB, so its contents were not read.
  - [DDJ-1000](https://web.archive.org/web/20250827124612/https://www.pioneerdj.com/-/media/pioneerdj/software-info/controller/ddj-1000/ddj-1000_midi_message_list_e1.pdf)
  - [DDJ-SX3](https://web.archive.org/web/20240518164243/https://www.pioneerdj.com/-/media/pioneerdj/software-info/controller/ddj-sx3/ddj-sx3_midi_message_list_e1.pdf)
  - [DDJ-REV1](https://web.archive.org/web/20240224053404/https://www.pioneerdj.com/-/media/pioneerdj/software-info/controller/ddj-rev1/ddj-rev1_midi_message_list_e1.pdf)
  - [DDJ-REV5](https://web.archive.org/web/20250623061926/https://www.pioneerdj.com/-/media/pioneerdj/software-info/controller/ddj-rev5/ddj-rev5_midi_message_list_e1.pdf)
  - [DDJ-REV7](https://web.archive.org/web/20241013145617/https://www.pioneerdj.com/-/media/pioneerdj/software-info/controller/ddj-rev7/ddj-rev7_midi_message_list_e1.pdf)

**Denon DJ / inMusic**
- [Denon DJ downloads](https://www.denondj.com/downloads.html)
- [LC6000 PRIME MIDI Specification v1.0](https://cdn.inmusicbrands.com/denondj/lc6000/LC6000-PRIME-MIDI-Specification-v1.0.pdf)
- [MC7000 Hardware Settings Mode Specification v1.4](http://cdn.inmusicbrands.com/denondj/MC7000/MC7000-Hardware-Settings-Mode-Specification-v1_4.pdf)
- [MC7000 product page](https://www.denondj.com/professional-dj-controller-for-serato-mc7000xus)
- Numark product pages: [Mixtrack Platinum FX](https://www.numark.com/product/mixtrack-platinum-fx), [Mixtrack Pro FX](https://www.numark.com/product/mixtrack-pro-fx)
- [Mixtrack Pro FX user guide v1.2](https://cdn.inmusicbrands.com/Numark/vAC9uYWEnT/mtprfx/MixTrackProFX-UserGuide-v1.2.pdf)

**Hercules**
- [Inpulse 500 support](https://support.hercules.com/en/product/djcontrolinpulse500-en/)
- [DJUCED Inpulse 500 mapping and manual](https://www.djuced.com/kb/hercules-djcontrol-inpulse-500/)

**Native Instruments**
- [Switching your controller to MIDI mode](https://support.native-instruments.com/support/solutions/articles/69000880031-native-instruments-switching-your-controller-to-midi-mode)

**Mixxx** (commit [`dc4bf99`](https://github.com/mixxxdj/mixxx/tree/dc4bf99322bb9a4c59483d24c2c40d1df2d1b726/res/controllers))
- Mapping files, all under `res/controllers/`:
  - `Pioneer-DDJ-400.midi.xml` and `-script.js`
  - `Pioneer-DDJ-FLX4.midi.xml` and `-script.js`
  - `Denon-MC7000.midi.xml` and `-scripts.js`
  - `Numark Mixtrack Platinum FX.midi.xml` and `Numark-Mixtrack-Platinum-FX-scripts.js`
  - `Numark Mixtrack Pro FX.midi.xml` and `Numark-Mixtrack-Pro-FX-scripts.js`
  - `Hercules_DJControl_Inpulse_500.midi.xml` and `Hercules-DJControl-Inpulse-500-script.js`
  - `Hercules_DJControl_Inpulse_300.midi.xml`
  - `Pioneer DDJ-SX.midi.xml`
  - `Traktor Kontrol S2 MK3.hid.xml`, `Traktor Kontrol S3.hid.xml`
- Manual pages under [`mixxxdj/manual` source/hardware/controllers](https://github.com/mixxxdj/manual/tree/main/source/hardware/controllers): `pioneer_ddj_400`, `pioneer_ddj_flx4`, `denon_mc7000`, `numark_mixtrack_platinum_fx`, `numark_mixtrack_pro_fx`, `numark_mixstream_pro`, `hercules_djcontrol_inpulse_300`, `hercules_djcontrol_inpulse_500`, `native_instruments_traktor_kontrol_s2_mk3`, `native_instruments_traktor_kontrol_s4_mk3`.

**Non-primary** (labeled where used)
- [whanake-music/denon-prime-4-analysis](https://github.com/whanake-music/denon-prime-4-analysis): third-party Prime 4 USB captures.
- [Engine DJ forum: SC Live 4 MIDI specification](https://community.enginedj.com/t/midi-specification-sc-live-4/51665): forum post.
- [Algoriddim forum: Rane One MIDI mapping](https://community.algoriddim.com/t/rane-one-midi-mapping/26978): forum post.
- [Algoriddim forum: Reloop Mixtour MIDI map](https://community.algoriddim.com/t/reloop-mixtour-pro-full-midi-map/38993): forum post.
