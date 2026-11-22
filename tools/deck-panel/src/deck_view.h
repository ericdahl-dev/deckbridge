// The deck screen and the waiting screen in LVGL (#620, #621, #665): what the core decides, drawn on the 800x480. The
// objects are built once and hold what's on screen; the core says which parts changed and this sets only those, keeping
// no copy of its own, so a frame allocates nothing here and a fast field redraws only its own box.
#pragma once

#include <lvgl.h>

#include "deck_core.h"
#include "deck_face.h"

class DeckScreen : public deck_core::Screen {
public:
    /// Builds both screens' objects on the active screen, both hidden. Call once, after display_init().
    void build();

    void show_waiting(const deck_core::WaitingView& view, const deck_core::WaitingChanges& changes) override;
    void show_deck(const deck_core::Face& face, const deck_core::Changes& changes) override;

private:
    void draw(const deck_core::Face& f, const deck_core::Changes& changes);

    struct Lamp {
        lv_obj_t* box = nullptr;
        lv_obj_t* text = nullptr;
    };

    lv_obj_t* deck_page_ = nullptr;
    lv_obj_t* deck_number_ = nullptr;
    lv_obj_t* title_ = nullptr;
    lv_obj_t* artist_ = nullptr;
    lv_obj_t* key_ = nullptr;
    lv_obj_t* bpm_ = nullptr;
    lv_obj_t* tempo_ = nullptr;
    lv_obj_t* elapsed_ = nullptr;
    lv_obj_t* remaining_ = nullptr;
    lv_obj_t* progress_fill_ = nullptr;
    lv_obj_t* beats_[4] = {};
    lv_obj_t* phase_ = nullptr;       ///< the phase bar's track
    lv_obj_t* phase_bar_ = nullptr;   ///< in the track: the bar from the center, in the deck color
    lv_obj_t* phase_tick_ = nullptr;  ///< on the page, over the track: the locked tick
    lv_obj_t* level_fill_ = nullptr;
    Lamp play_, cue_, sync_, master_, loop_;
    lv_obj_t* waiting_page_ = nullptr;
    lv_obj_t* logo_ = nullptr;  ///< above the headline, shown when the view asks for it
    lv_obj_t* headline_ = nullptr;
    lv_obj_t* detail_ = nullptr;
    lv_obj_t* build_ = nullptr;  ///< the firmware's version and SHA, bottom right (#695)
};
