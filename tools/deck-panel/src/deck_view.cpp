#include "deck_view.h"


#include "board_pins.h"

// Geist (OFL), converted by fonts/make_fonts.sh into src/fonts/.
LV_FONT_DECLARE(geist_semibold_36)
LV_FONT_DECLARE(geist_regular_24)
LV_FONT_DECLARE(geist_mono_medium_32)
LV_FONT_DECLARE(geist_mono_semibold_64)
// The logo (#651), made from the icon's SVG by deck_logo.py into src/deck_logo.c.
LV_IMAGE_DECLARE(deck_logo);
// Half size, for the setup screen's longer text (#677). Swapped in whole: no scaling, so still a plain copy.
LV_IMAGE_DECLARE(deck_logo_small);

namespace {

using namespace deck_core::layout;

namespace palette = deck_core::palette;
const lv_color_t kGray = lv_color_hex(palette::kGray);
const lv_color_t kDim = lv_color_hex(palette::kDim);
const lv_color_t kTrack = lv_color_hex(palette::kTrack);

/// A full-screen page with no style of its own on the black screen, hidden.
lv_obj_t* page(lv_obj_t* parent) {
    lv_obj_t* box = lv_obj_create(parent);
    lv_obj_remove_style_all(box);
    lv_obj_set_size(box, board::LCD_WIDTH, board::LCD_HEIGHT);
    lv_obj_remove_flag(box, LV_OBJ_FLAG_SCROLLABLE);
    lv_obj_add_flag(box, LV_OBJ_FLAG_HIDDEN);
    return box;
}

/// An opaque box: bars, blocks, markers. Opaque and untransformed, so drawing it needs no layer.
lv_obj_t* box(lv_obj_t* parent, int x, int y, int w, int h, lv_color_t color) {
    lv_obj_t* b = lv_obj_create(parent);
    lv_obj_remove_style_all(b);
    lv_obj_remove_flag(b, LV_OBJ_FLAG_SCROLLABLE);
    lv_obj_remove_flag(b, LV_OBJ_FLAG_CLICKABLE);
    lv_obj_set_pos(b, x, y);
    lv_obj_set_size(b, w, h);
    lv_obj_set_style_bg_color(b, color, 0);
    lv_obj_set_style_bg_opa(b, LV_OPA_COVER, 0);
    return b;
}

/// A label `width` wide, in `font` and `color`, wrapped and cut at `lines`. Not LVGL's dot mode: it measures
/// against the label's old height, so a one-line label never grows, and it writes dots into the text. Never scroll
/// mode, which redraws every frame. The core already cuts at 40 characters with "…", so the cut is a backstop.
lv_obj_t* label(lv_obj_t* parent, int width, const lv_font_t* font, lv_color_t color, lv_text_align_t align,
                int lines) {
    lv_obj_t* l = lv_label_create(parent);
    lv_obj_set_width(l, width);
    lv_obj_set_style_text_font(l, font, 0);
    lv_obj_set_style_text_color(l, color, 0);
    lv_obj_set_style_text_align(l, align, 0);
    lv_obj_set_style_max_height(l, lv_font_get_line_height(font) * lines, 0);
    lv_label_set_long_mode(l, LV_LABEL_LONG_WRAP);
    lv_label_set_text_static(l, "");
    return l;
}

/// A one-line label with a fixed place and size, so a new text redraws that box and nothing else.
lv_obj_t* field(lv_obj_t* parent, int x, int y, int w, const lv_font_t* font, lv_color_t color,
                lv_text_align_t align = LV_TEXT_ALIGN_LEFT) {
    lv_obj_t* l = lv_label_create(parent);
    lv_obj_set_pos(l, x, y);
    lv_obj_set_size(l, w, lv_font_get_line_height(font));
    lv_obj_set_style_text_font(l, font, 0);
    lv_obj_set_style_text_color(l, color, 0);
    lv_obj_set_style_text_align(l, align, 0);
    lv_label_set_long_mode(l, LV_LABEL_LONG_CLIP);
    lv_label_set_text_static(l, "");
    return l;
}

void set_hidden(lv_obj_t* obj, bool hidden) {
    if (lv_obj_has_flag(obj, LV_OBJ_FLAG_HIDDEN) == hidden) return;
    if (hidden) lv_obj_add_flag(obj, LV_OBJ_FLAG_HIDDEN);
    else lv_obj_remove_flag(obj, LV_OBJ_FLAG_HIDDEN);
}


}  // namespace

void DeckScreen::build() {
    lv_obj_t* screen = lv_screen_active();
    lv_obj_set_style_bg_color(screen, lv_color_black(), 0);
    lv_obj_set_style_bg_opa(screen, LV_OPA_COVER, 0);
    lv_obj_remove_flag(screen, LV_OBJ_FLAG_SCROLLABLE);

    // The deck. The objects only: the first show_deck is every part, and sets them all.
    deck_page_ = page(screen);
    deck_number_ = field(deck_page_, kLeft, 12, 70, &geist_mono_semibold_64, lv_color_white());

    // Title (up to two lines) and artist across the top; the artist follows the title's height, inside this box.
    lv_obj_t* header = lv_obj_create(deck_page_);
    lv_obj_remove_style_all(header);
    lv_obj_remove_flag(header, LV_OBJ_FLAG_SCROLLABLE);
    const int header_w = board::LCD_WIDTH - kLeft - kHeaderX;
    lv_obj_set_pos(header, kHeaderX, kHeaderY);
    lv_obj_set_size(header, header_w, kInfoY - kHeaderY - 6);
    lv_obj_set_style_pad_row(header, 4, 0);
    lv_obj_set_flex_flow(header, LV_FLEX_FLOW_COLUMN);
    title_ = label(header, header_w, &geist_semibold_36, lv_color_white(), LV_TEXT_ALIGN_LEFT, 2);
    artist_ = label(header, header_w, &geist_regular_24, kGray, LV_TEXT_ALIGN_LEFT, 1);

    // Key, BPM, tempo: gray names on the values' baseline (Geist 24's sits 8 px lower in its line than Mono 32's).
    const lv_font_t* small = &geist_regular_24;
    const lv_font_t* mono = &geist_mono_medium_32;
    // Names' widths from the font: Key 42, BPM 53, Tempo 76 px. Values: "F#m", "1000.00", "+100.00%" in 19.2 px cells.
    lv_label_set_text_static(field(deck_page_, kLeft, kInfoY + 8, 48, small, kGray), "Key");
    key_ = field(deck_page_, 76, kInfoY, 100, mono, lv_color_white());
    lv_label_set_text_static(field(deck_page_, 200, kInfoY + 8, 60, small, kGray), "BPM");
    bpm_ = field(deck_page_, 264, kInfoY, 150, mono, lv_color_white());
    lv_label_set_text_static(field(deck_page_, 438, kInfoY + 8, 84, small, kGray), "Tempo");
    tempo_ = field(deck_page_, 526, kInfoY, 180, mono, lv_color_white());

    // Elapsed left, remaining right, large, in mono so the digits don't jitter.
    elapsed_ = field(deck_page_, kLeft, kTimeY, kWidth / 2, &geist_mono_semibold_64, lv_color_white());
    remaining_ = field(deck_page_, kLeft + kWidth / 2, kTimeY, kWidth / 2, &geist_mono_semibold_64, lv_color_white(),
                       LV_TEXT_ALIGN_RIGHT);

    // The progress bar: a fill on a track, its width the progress.
    lv_obj_t* progress = box(deck_page_, kLeft, kProgressY, kWidth, kProgressH, kTrack);
    progress_fill_ = box(progress, 0, 0, 0, kProgressH, lv_color_hex(palette::kProgress));

    // The beat in the bar: four blocks, the lit one in the deck color.
    const int beat_w = (kWidth - 3 * kBeatGap) / 4;
    for (int i = 0; i < 4; ++i) {
        beats_[i] = box(deck_page_, kLeft + i * (beat_w + kBeatGap), kBeatY, beat_w, kBeatH, kTrack);
    }

    // The phase bar (#721, the jog display's rule, #462): the track, a bar in the deck color from the center off
    // phase (0 wide, so hidden, until the core says), and the locked tick. The tick is on the page, after the track so
    // drawn over it, not in it: it reaches kPhaseTickReach past the track above and below, which the track would clip.
    phase_ = box(deck_page_, kLeft, kPhaseY, kWidth, kPhaseH, kTrack);
    phase_bar_ = box(phase_, 0, 0, 0, kPhaseH, lv_color_white());
    lv_obj_add_flag(phase_bar_, LV_OBJ_FLAG_HIDDEN);
    phase_tick_ = box(deck_page_, kLeft + kWidth / 2 - kPhaseTickW / 2, kPhaseY - kPhaseTickReach, kPhaseTickW,
                      kPhaseH + 2 * kPhaseTickReach, lv_color_white());
    lv_obj_add_flag(phase_tick_, LV_OBJ_FLAG_HIDDEN);

    // The lamps: lit is the lamp's color with black text.
    const int lamp_w = (kWidth - 4 * kLampGap) / 5;
    Lamp* lamps[] = {&play_, &cue_, &sync_, &master_, &loop_};
    const char* names[] = {"PLAY", "CUE", "SYNC", "MASTER", "LOOP"};
    for (int i = 0; i < 5; ++i) {
        Lamp& lamp = *lamps[i];
        lamp.box = box(deck_page_, kLeft + i * (lamp_w + kLampGap), kLampY, lamp_w, kLampH, kTrack);
        lv_obj_set_style_radius(lamp.box, 6, 0);
        lamp.text = field(lamp.box, 0, (kLampH - lv_font_get_line_height(small)) / 2, lamp_w, small, kDim,
                          LV_TEXT_ALIGN_CENTER);
        lv_label_set_text_static(lamp.text, names[i]);
    }

    // The level meter: a fill from the bottom.
    lv_obj_t* meter = box(deck_page_, kMeterX, kMeterY, kMeterW, kMeterH, kTrack);
    level_fill_ = box(meter, 0, 0, kMeterW, 0, lv_color_hex(palette::kLevel));
    lv_obj_set_align(level_fill_, LV_ALIGN_BOTTOM_LEFT);

    // Waiting: the logo, then why and what to do, in the middle. The logo is opaque RGB565 at its own size and
    // untransformed, so LVGL copies it from flash with no layer and no decoded copy. 184 wide by 198 high: stretched
    // down for the panel's short pixels (README, "Round things"), and with two headline lines (2x44), three detail
    // lines (3x30) and two 12 px gaps the column is exactly the 400 px between the margins.
    waiting_page_ = page(screen);
    lv_obj_set_style_pad_all(waiting_page_, kMargin, 0);
    lv_obj_set_style_pad_row(waiting_page_, 12, 0);
    lv_obj_set_flex_flow(waiting_page_, LV_FLEX_FLOW_COLUMN);
    lv_obj_set_flex_align(waiting_page_, LV_FLEX_ALIGN_CENTER, LV_FLEX_ALIGN_CENTER, LV_FLEX_ALIGN_CENTER);
    const int waiting_w = board::LCD_WIDTH - 2 * kMargin;
    logo_ = lv_image_create(waiting_page_);
    lv_image_set_src(logo_, &deck_logo);
    lv_obj_add_flag(logo_, LV_OBJ_FLAG_HIDDEN);
    headline_ = label(waiting_page_, waiting_w, &geist_semibold_36, lv_color_white(), LV_TEXT_ALIGN_CENTER, 2);
    detail_ = label(waiting_page_, waiting_w, &geist_regular_24, kGray, LV_TEXT_ALIGN_CENTER, 3);
    // The firmware's version and SHA (#695): floating, bottom right, vertically centered in the bottom margin, so the
    // column keeps its 400 px.
    build_ = label(waiting_page_, waiting_w, &geist_regular_24, kGray, LV_TEXT_ALIGN_RIGHT, 1);
    lv_obj_add_flag(build_, LV_OBJ_FLAG_FLOATING);
    lv_obj_align(build_, LV_ALIGN_BOTTOM_RIGHT, 0, (kMargin + lv_font_get_line_height(&geist_regular_24)) / 2);
}

void DeckScreen::show_waiting(const deck_core::WaitingView& view, const deck_core::WaitingChanges& changes) {
    // The view is the core's and stays put until the next call: the labels point at its texts.
    if (changes.headline) lv_label_set_text_static(headline_, view.headline);
    if (changes.detail) lv_label_set_text_static(detail_, view.detail);
    if (changes.build) lv_label_set_text_static(build_, view.build);
    if (changes.logo_small) lv_image_set_src(logo_, view.logo_small ? &deck_logo_small : &deck_logo);
    if (changes.logo) set_hidden(logo_, !view.logo);
    set_hidden(deck_page_, true);
    set_hidden(waiting_page_, false);
}

void DeckScreen::show_deck(const deck_core::Face& f, const deck_core::Changes& c) {
    draw(f, c);
    set_hidden(waiting_page_, true);
    set_hidden(deck_page_, false);
}

void DeckScreen::draw(const deck_core::Face& f, const deck_core::Changes& c) {
    using deck_core::Part;
    // Texts: the face is the core's and stays put until the next call, so each label points at it.
    struct {
        Part part;
        lv_obj_t* label;
        const char* text;
    } texts[] = {{Part::deck, deck_number_, f.deck},   {Part::title, title_, f.title},
                 {Part::artist, artist_, f.artist},    {Part::key, key_, f.key},
                 {Part::bpm, bpm_, f.bpm},             {Part::tempo, tempo_, f.tempo},
                 {Part::elapsed, elapsed_, f.elapsed}, {Part::remaining, remaining_, f.remaining},
                 {Part::loop_label, loop_.text, f.loop_label}};
    for (const auto& t : texts) {
        if (c.has(t.part)) lv_label_set_text_static(t.label, t.text);
    }
    if (c.has(Part::deck_color)) {
        lv_obj_set_style_text_color(deck_number_, lv_color_hex(f.deck_color), 0);
        // The phase bar is the deck color, not a color of its own in the face (the beats' come resolved).
        lv_obj_set_style_bg_color(phase_bar_, lv_color_hex(f.deck_color), 0);
    }

    // Fast: the core tells only whole-pixel moves.
    if (c.has(Part::progress_px)) lv_obj_set_width(progress_fill_, f.progress_px);
    if (c.has(Part::progress_color)) lv_obj_set_style_bg_color(progress_fill_, lv_color_hex(f.progress_color), 0);
    for (int i = 0; i < 4; ++i) {
        if (c.has(Part::beat_color, i)) lv_obj_set_style_bg_color(beats_[i], lv_color_hex(f.beat_color[i]), 0);
    }
    if (c.has(Part::phase_track_color)) lv_obj_set_style_bg_color(phase_, lv_color_hex(f.phase_track_color), 0);
    if (c.has(Part::phase_bar_x)) lv_obj_set_x(phase_bar_, f.phase_bar_x);
    if (c.has(Part::phase_bar_w)) {
        if (f.phase_bar_w > 0) lv_obj_set_width(phase_bar_, f.phase_bar_w);
        set_hidden(phase_bar_, f.phase_bar_w <= 0);
    }
    if (c.has(Part::phase_tick)) set_hidden(phase_tick_, f.phase_tick == 0);
    if (c.has(Part::phase_tick_color)) lv_obj_set_style_bg_color(phase_tick_, lv_color_hex(f.phase_tick_color), 0);
    if (c.has(Part::level_px)) lv_obj_set_height(level_fill_, f.level_px);

    Lamp* lamps[] = {&play_, &cue_, &sync_, &master_, &loop_};
    for (int i = 0; i < deck_core::kLamps; ++i) {
        if (c.has(Part::lamp_color, i)) lv_obj_set_style_bg_color(lamps[i]->box, lv_color_hex(f.lamp_color[i]), 0);
        if (c.has(Part::lamp_text_color, i)) {
            lv_obj_set_style_text_color(lamps[i]->text, lv_color_hex(f.lamp_text_color[i]), 0);
        }
    }
}
