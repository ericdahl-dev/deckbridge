// The panel_scan::Panel on esp_lcd (#666). The bring-up is #635's, moved here from display_driver.cpp; see
// LICENSE.crowpanel-drivers.
//
// Author: Mark Castelluccio <markacastelluccio@gmail.com>
// Written with assistance from Claude Code (Anthropic).

#include "board_panel.h"

#include <Arduino.h>
#include <esp_lcd_panel_ops.h>
#include <esp_timer.h>

#include "board_pins.h"

using panel_scan::Signal;

namespace {
int index(Signal s) { return static_cast<int>(s); }
}  // namespace

// The interrupt isn't IRAM-safe in this core's build (no CONFIG_LCD_RGB_ISR_IRAM_SAFE), so it never runs while the
// flash cache is off, and the Scan's flash-resident code is fine from here, as the swap gate's was before #666.
//
// Without bounce buffers the vsync is the latch (the Scan knows from its config); with them it's the frame clock's
// other wake (#679), about 1.9 ms after the latch. On the loop's core, so the loop runs only after this interrupt
// ends, the driver's vsync restart included.
bool IRAM_ATTR BoardPanel::on_vsync(esp_lcd_panel_handle_t, const esp_lcd_rgb_panel_event_data_t*, void* ctx) {
    BoardPanel* self = static_cast<BoardPanel*>(ctx);
    self->scan_->vsync(static_cast<uint64_t>(esp_timer_get_time()));
    return self->take_woken();
}

// With bounce buffers the driver picks the next frame's buffer here, when it has copied the last of this one, not at
// the vsync: the latch. Registered only with bounce buffers.
bool IRAM_ATTR BoardPanel::on_frame_buf_complete(esp_lcd_panel_handle_t, const esp_lcd_rgb_panel_event_data_t*,
                                                 void* ctx) {
    BoardPanel* self = static_cast<BoardPanel*>(ctx);
    self->scan_->frame_complete(static_cast<uint64_t>(esp_timer_get_time()));
    return self->take_woken();
}

void IRAM_ATTR BoardPanel::give(Signal signal) {
    // The Scan stamps a latch before its gives: mirror it for the copy wrapper and the ledger's on-glass time.
    if (signal != Signal::vsync) {
        const uint32_t us = static_cast<uint32_t>(scan_->latches().us);
        if (signal == Signal::latch) latch_us_ = us;
        else release_us_ = us;
    }
    if (xPortInIsrContext()) {
        xSemaphoreGiveFromISR(sem_[index(signal)], &woken_);
    } else {
        xSemaphoreGive(sem_[index(signal)]);
    }
}

void BoardPanel::drop(Signal signal) { xSemaphoreTake(sem_[index(signal)], 0); }

bool BoardPanel::take(Signal signal, uint32_t timeout_ms) {
    return xSemaphoreTake(sem_[index(signal)], pdMS_TO_TICKS(timeout_ms)) == pdTRUE;
}

uint64_t IRAM_ATTR BoardPanel::now() const { return static_cast<uint64_t>(esp_timer_get_time()); }

// The _SAFE pair: the Scan locks from the panel interrupt and from tasks.
void IRAM_ATTR BoardPanel::lock() { portENTER_CRITICAL_SAFE(&mux_); }
void IRAM_ATTR BoardPanel::unlock() { portEXIT_CRITICAL_SAFE(&mux_); }

// Direct mode: the whole hidden framebuffer, drawn in place. In bounce mode draw_bitmap only switches buffers: the
// bounce copy reads through the same cache LVGL wrote to. Without bounce buffers it also writes the cache back over
// the range given, and every area of this frame, plus what LVGL copied over from the last one, may still be in the
// cache: so the whole frame, not the last area.
void BoardPanel::hand_over() {
    const int64_t start = esp_timer_get_time();
    // Only bad arguments fail it, and these are fixed; the frame is handed over either way.
    (void)esp_lcd_panel_draw_bitmap(panel_, 0, 0, config_.timing.width, config_.timing.height, frame_);
    const int64_t end = esp_timer_get_time();
    draw_bitmap_us_ += static_cast<uint32_t>(end - start);
    // The latches so far count as before this swap: read here, after the draw_bitmap and before the Scan arms its gate,
    // where 1d0683fd read them, so the ledger adds nothing between the two.
    swap_latches_ = scan_->latches();
    swapped_us_ = static_cast<uint32_t>(end);
}

bool BoardPanel::frame_buffers(void** fb0, void** fb1) const {
    if (panel_ == nullptr) return false;
    return esp_lcd_rgb_panel_get_frame_buffer(panel_, 2, fb0, fb1) == ESP_OK && *fb0 != nullptr && *fb1 != nullptr;
}

bool BoardPanel::start(const panel_scan::Config& config) {
    if (scan_ == nullptr) return false;
    config_ = config;
    // Before the panel: its interrupts start with esp_lcd_panel_init and give these.
    for (int i = 0; i < 3; ++i) {
        sem_[i] = xSemaphoreCreateBinaryStatic(&sem_store_[i]);
        if (sem_[i] == nullptr) return false;
    }
    return init_on_core();
}

bool BoardPanel::init() {
    const frame_pacing::Timing& t = config_.timing;
    esp_lcd_rgb_panel_config_t cfg = {};
    cfg.clk_src = LCD_CLK_SRC_DEFAULT;  // PLL 160 MHz; the LCD clock divider takes fractions, so 12.3 MHz is near
    cfg.timings.pclk_hz = t.pclk_hz;
    cfg.timings.h_res = t.width;
    cfg.timings.v_res = t.height;
    cfg.timings.hsync_pulse_width = t.h_pulse;
    cfg.timings.hsync_back_porch = t.h_back;
    cfg.timings.hsync_front_porch = t.h_front;
    cfg.timings.vsync_pulse_width = t.v_pulse;
    cfg.timings.vsync_back_porch = t.v_back;
    cfg.timings.vsync_front_porch = t.v_front;
    cfg.timings.flags.hsync_idle_low = PANEL_HSYNC_IDLE_LOW;
    cfg.timings.flags.vsync_idle_low = PANEL_VSYNC_IDLE_LOW;
    cfg.timings.flags.de_idle_high = PANEL_DE_IDLE_HIGH;
    cfg.timings.flags.pclk_active_neg = PANEL_PCLK_ACTIVE_NEG;
    cfg.timings.flags.pclk_idle_high = PANEL_PCLK_IDLE_HIGH;
    cfg.data_width = 16;
    cfg.bits_per_pixel = 16;
    cfg.num_fbs = 2;
    cfg.bounce_buffer_size_px = config_.bounce_px;
    cfg.dma_burst_size = 64;  // the largest burst; it reads the bounce buffers in internal RAM, or PSRAM without them
    cfg.hsync_gpio_num = board::LCD_HSYNC;
    cfg.vsync_gpio_num = board::LCD_VSYNC;
    cfg.de_gpio_num = board::LCD_DE;
    cfg.pclk_gpio_num = board::LCD_PCLK;
    cfg.disp_gpio_num = -1;  // no display-enable line: the companion chip owns power and backlight
    // Bus order as LovyanGFX's pin_d0..d15: blue low, red high.
    const int data[16] = {board::LCD_B0, board::LCD_B1, board::LCD_B2, board::LCD_B3, board::LCD_B4, board::LCD_G0,
                          board::LCD_G1, board::LCD_G2, board::LCD_G3, board::LCD_G4, board::LCD_G5, board::LCD_R0,
                          board::LCD_R1, board::LCD_R2, board::LCD_R3, board::LCD_R4};
    for (int i = 0; i < 16; ++i) cfg.data_gpio_nums[i] = data[i];
    cfg.flags.fb_in_psram = 1;

    esp_err_t err = esp_lcd_new_rgb_panel(&cfg, &panel_);
    if (err != ESP_OK) {
        Serial.printf("display: esp_lcd_new_rgb_panel failed: %s\n", esp_err_to_name(err));
        panel_ = nullptr;
        return false;
    }
    esp_lcd_rgb_panel_event_callbacks_t cbs = {};
    cbs.on_vsync = on_vsync;
    if (config_.bounce_px > 0) cbs.on_frame_buf_complete = on_frame_buf_complete;
    err = esp_lcd_rgb_panel_register_event_callbacks(panel_, &cbs, this);
    if (err == ESP_OK) err = esp_lcd_panel_reset(panel_);
    if (err == ESP_OK) err = esp_lcd_panel_init(panel_);
    if (err != ESP_OK) {
        Serial.printf("display: panel bring-up failed: %s\n", esp_err_to_name(err));
        esp_lcd_panel_del(panel_);
        panel_ = nullptr;
        return false;
    }
    return true;
}

// init() on PANEL_ISR_CORE: esp_lcd allocates the panel's interrupts on the core that creates it.
namespace {
struct CoreInit {
    BoardPanel* panel;
    SemaphoreHandle_t done;
    bool ok;
};
}  // namespace

void BoardPanel::init_task(void* arg) {
    CoreInit* init = static_cast<CoreInit*>(arg);
    init->ok = init->panel->init();
    xSemaphoreGive(init->done);
    vTaskDelete(nullptr);
}

bool BoardPanel::init_on_core() {
    if (xPortGetCoreID() == PANEL_ISR_CORE) return init();
    StaticSemaphore_t done_store;
    CoreInit init = {this, xSemaphoreCreateBinaryStatic(&done_store), false};
    if (init.done == nullptr) return false;
    const bool started =
        xTaskCreatePinnedToCore(init_task, "panel_init", 4096, &init, 5, nullptr, PANEL_ISR_CORE) == pdPASS;
    if (started) xSemaphoreTake(init.done, portMAX_DELAY);
    vSemaphoreDelete(init.done);
    if (!started) Serial.println("display: couldn't start the panel on its core");
    return started && init.ok;
}
