#include "wifi_page.h"

#include <algorithm>
#include <cstring>
#include <vector>

namespace wifi_setup {
namespace {

std::string escape(const char* s) {
    std::string out;
    for (; *s; ++s) {
        switch (*s) {
            case '<': out += "&lt;"; break;
            case '>': out += "&gt;"; break;
            case '&': out += "&amp;"; break;
            case '"': out += "&quot;"; break;
            case '\'': out += "&#39;"; break;
            default: out += *s;
        }
    }
    return out;
}

const char* kHead =
    "<!doctype html><html lang=\"en\"><head><meta charset=\"utf-8\">"
    "<meta name=\"viewport\" content=\"width=device-width,initial-scale=1\"><title>Deck panel Wi-Fi</title>"
    "<style>body{font:17px system-ui,sans-serif;margin:24px auto;max-width:28em;padding:0 16px}"
    "label{display:block;margin:6px 0}input[type=text],input[type=password]{width:100%;font:inherit;padding:8px;"
    "box-sizing:border-box}button{font:inherit;padding:10px 20px;margin-top:12px}.error{color:#b00020}"
    ".dim{color:#666}</style></head><body>";

}  // namespace

std::string setup_page(const Seen* seen, size_t count, const char* error, const char* panel_network) {
    // Strongest first; each name once, at its strongest; hidden networks (no name) left out.
    std::vector<Seen> list;
    for (size_t i = 0; i < count; ++i) {
        if (seen[i].ssid == nullptr || seen[i].ssid[0] == 0) continue;
        auto same = std::find_if(list.begin(), list.end(),
                                 [&](const Seen& s) { return std::strcmp(s.ssid, seen[i].ssid) == 0; });
        if (same == list.end()) {
            list.push_back(seen[i]);
        } else if (seen[i].rssi > same->rssi) {
            same->rssi = seen[i].rssi;
        }
    }
    std::stable_sort(list.begin(), list.end(), [](const Seen& a, const Seen& b) { return a.rssi > b.rssi; });

    std::string page = kHead;
    page += "<h1>Deck panel Wi-Fi</h1><p class=\"dim\">On ";
    page += escape(panel_network);
    page += ". Pick the panel's Wi-Fi (2.4 GHz only) and give its password.</p>";
    if (error && error[0]) {
        page += "<p class=\"error\">";
        page += escape(error);
        page += "</p>";
    }
    page += "<form method=\"post\" action=\"/save\">";
    for (const Seen& s : list) {
        const std::string name = escape(s.ssid);
        page += "<label><input type=\"radio\" name=\"ssid\" value=\"" + name + "\"> " + name + "</label>";
    }
    if (list.empty()) page += "<p class=\"dim\">No networks found. Type the name below.</p>";
    page += "<label>Or type a name (a hidden network)<input type=\"text\" name=\"ssid_other\" maxlength=\"32\" "
            "autocapitalize=\"none\" autocorrect=\"off\"></label>"
            "<label>Password (empty for an open network)"
            "<input type=\"password\" name=\"password\" autocomplete=\"off\"></label>"
            "<button type=\"submit\">Save and restart</button></form>"
            "<p class=\"dim\">Reload this page to scan again.</p></body></html>";
    return page;
}

std::string saved_page(const char* ssid) {
    std::string page = kHead;
    page += "<h1>Saved</h1><p>The panel is restarting and will join <b>";
    page += escape(ssid);
    page += "</b>. This setup network goes away; rejoin your usual Wi-Fi.</p>"
            "<p class=\"dim\">If it can't join, hold the panel's screen for 5 seconds to set it up again.</p>"
            "</body></html>";
    return page;
}

}  // namespace wifi_setup
