// The screen stub: records what the core decided to show, as the board layer would draw it.
#pragma once

#include <cstdlib>
#include <string>
#include <vector>

#include "deck_core.h"

struct ScreenStub : deck_core::Screen {
    struct Shown {
        bool waiting = true;
        int deck = 0;  ///< the face's number, 0 for none
        uint32_t color = 0;  ///< the face's deck color
        std::string title;  ///< as the face shows them
        std::string artist;
        std::string headline;  ///< the waiting screen's
        std::string detail;
        bool logo = false;  ///< the waiting screen's DeckBridge logo
        bool logo_small = false;  ///< at half size (setup, #677)
        deck_core::Face face;  ///< the whole face, as shown
        deck_core::Changes changes;  ///< the parts the core said changed
        deck_core::WaitingChanges waiting_changes;
    };
    std::vector<Shown> shown;

    void show_waiting(const deck_core::WaitingView& view, const deck_core::WaitingChanges& changes) override {
        Shown s;
        s.waiting_changes = changes;
        s.headline = view.headline;
        s.detail = view.detail;
        s.logo = view.logo;
        s.logo_small = view.logo_small;
        shown.push_back(s);
    }
    void show_deck(const deck_core::Face& face, const deck_core::Changes& changes) override {
        Shown s;
        s.waiting = false;
        s.deck = std::atoi(face.deck);
        s.color = face.deck_color;
        s.title = face.title;
        s.artist = face.artist;
        s.face = face;
        s.changes = changes;
        shown.push_back(s);
    }
    const Shown& last() const { return shown.back(); }
};
