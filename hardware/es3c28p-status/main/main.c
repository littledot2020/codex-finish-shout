#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>

#include "driver/gpio.h"
#include "driver/i2c_master.h"
#include "driver/i2s.h"
#include "driver/spi_master.h"
#include "driver/usb_serial_jtag.h"
#include "driver/usb_serial_jtag_vfs.h"
#include "cJSON.h"
#include "esp_attr.h"
#include "esp_check.h"
#include "esp_lcd_ili9341.h"
#include "esp_lcd_panel_io.h"
#include "esp_lcd_panel_ops.h"
#include "esp_log.h"
#include "esp_timer.h"
#include "freertos/FreeRTOS.h"
#include "freertos/semphr.h"
#include "freertos/task.h"

#define LCD_WIDTH 320
#define LCD_HEIGHT 240
#define LCD_SCLK 12
#define LCD_MOSI 11
#define LCD_MISO 13
#define LCD_DC 46
#define LCD_CS 10
#define LCD_BACKLIGHT 45

#define I2C_SDA 16
#define I2C_SCL 15
#define ES8311_ADDRESS 0x18
#define AUDIO_ENABLE 1
#define I2S_BCLK 5
#define I2S_LRCK 7
#define I2S_DOUT 8
#define I2S_MCLK 4
#define AUDIO_SAMPLE_RATE 44100
#define AUDIO_MCLK (AUDIO_SAMPLE_RATE * 256)

#define RX_LINE_CAPACITY 8192
#define PROJECT_CAPACITY 1024
#define MESSAGE_CAPACITY 256
#define TEXT_CAPACITY (PROJECT_CAPACITY + MESSAGE_CAPACITY + 3)
#define TEXT_SCALE 3
#define TEXT_TOP 94
#define PROJECT_ROW_COUNT 6
#define PROJECT_ROW_HEIGHT (LCD_HEIGHT / PROJECT_ROW_COUNT)
#define PROJECT_NAME_CAPACITY 192
#define PROJECT_NAME_SCALE 1
#define PROJECT_STATUS_SCALE 2
#define PROJECT_NAME_X 6
#define PROJECT_NAME_RIGHT 238
#define PROJECT_STATUS_LEFT 246
#define PROJECT_STATUS_RIGHT 316
#define FRAME_PERIOD_MS 80
#define PROJECT_SNAPSHOT_TIMEOUT_SECONDS 90
#define PROJECT_SNAPSHOT_TIMEOUT_US ((int64_t)PROJECT_SNAPSHOT_TIMEOUT_SECONDS * 1000000LL)
#define LCD_DRAW_LINES 16
#define AUDIO_EVENT_QUEUE_LENGTH 8
#define AUDIO_TASK_STACK_SIZE 4096
#define DISPLAY_TASK_STACK_SIZE 8192
#define SERIAL_TASK_STACK_SIZE 8192

static const char *TAG = "codex_es3c28p";
static esp_lcd_panel_handle_t s_panel;
static SemaphoreHandle_t s_state_mutex;
static SemaphoreHandle_t s_audio_event;
static SemaphoreHandle_t s_lcd_done;
static char s_text[TEXT_CAPACITY] = "WAITING FOR HOST";
static char s_rx_line[RX_LINE_CAPACITY];
static DMA_ATTR uint16_t s_lcd_buffer[LCD_WIDTH * LCD_DRAW_LINES];
static uint16_t s_background = 0x39E7;
static uint16_t s_foreground = 0xFFFF;
static int s_scroll_x = LCD_WIDTH;
static bool s_completion = false;
static bool s_audio_ready = false;
static int64_t s_last_project_snapshot_us;
static bool s_host_offline;

typedef struct {
    char name[PROJECT_NAME_CAPACITY];
    bool completed;
} project_row_t;

typedef struct {
    bool snapshot_active;
    size_t project_count;
    int project_total;
    project_row_t projects[PROJECT_ROW_COUNT];
} project_snapshot_t;

/* Serial writes this state under s_state_mutex. The display task copies it to
 * its own static snapshot before drawing, so neither the task stack nor the
 * DMA buffer is used as long-lived shared storage. */
static project_snapshot_t s_projects;
static project_snapshot_t s_render_projects;

static bool project_snapshot_timed_out(int64_t now_us, int64_t last_snapshot_us)
{
    return now_us >= last_snapshot_us &&
           now_us - last_snapshot_us >= PROJECT_SNAPSHOT_TIMEOUT_US;
}

static void expire_stale_project_snapshot(void)
{
    const int64_t now_us = esp_timer_get_time();
    bool became_offline = false;

    xSemaphoreTake(s_state_mutex, portMAX_DELAY);
    if (!s_host_offline && project_snapshot_timed_out(now_us, s_last_project_snapshot_us)) {
        memset(&s_projects, 0, sizeof(s_projects));
        s_completion = false;
        s_host_offline = true;
        became_offline = true;
    }
    xSemaphoreGive(s_state_mutex);

    if (became_offline) {
        ESP_LOGW(TAG, "no valid project snapshot for %d seconds; host marked offline",
                 PROJECT_SNAPSHOT_TIMEOUT_SECONDS);
    }
}

static const uint8_t kDigits[10][5] = {
    {0x3E,0x51,0x49,0x45,0x3E},{0x00,0x42,0x7F,0x40,0x00},
    {0x42,0x61,0x51,0x49,0x46},{0x21,0x41,0x45,0x4B,0x31},
    {0x18,0x14,0x12,0x7F,0x10},{0x27,0x45,0x45,0x45,0x39},
    {0x3C,0x4A,0x49,0x49,0x30},{0x01,0x71,0x09,0x05,0x03},
    {0x36,0x49,0x49,0x49,0x36},{0x06,0x49,0x49,0x29,0x1E}
};

static const uint8_t kUpper[26][5] = {
    {0x7E,0x11,0x11,0x11,0x7E},{0x7F,0x49,0x49,0x49,0x36},
    {0x3E,0x41,0x41,0x41,0x22},{0x7F,0x41,0x41,0x22,0x1C},
    {0x7F,0x49,0x49,0x49,0x41},{0x7F,0x09,0x09,0x09,0x01},
    {0x3E,0x41,0x49,0x49,0x7A},{0x7F,0x08,0x08,0x08,0x7F},
    {0x00,0x41,0x7F,0x41,0x00},{0x20,0x40,0x41,0x3F,0x01},
    {0x7F,0x08,0x14,0x22,0x41},{0x7F,0x40,0x40,0x40,0x40},
    {0x7F,0x02,0x0C,0x02,0x7F},{0x7F,0x04,0x08,0x10,0x7F},
    {0x3E,0x41,0x41,0x41,0x3E},{0x7F,0x09,0x09,0x09,0x06},
    {0x3E,0x41,0x51,0x21,0x5E},{0x7F,0x09,0x19,0x29,0x46},
    {0x46,0x49,0x49,0x49,0x31},{0x01,0x01,0x7F,0x01,0x01},
    {0x3F,0x40,0x40,0x40,0x3F},{0x1F,0x20,0x40,0x20,0x1F},
    {0x3F,0x40,0x30,0x40,0x3F},{0x63,0x14,0x08,0x14,0x63},
    {0x07,0x08,0x70,0x08,0x07},{0x61,0x51,0x49,0x45,0x43}
};

static const uint8_t kLower[26][5] = {
    {0x20,0x54,0x54,0x54,0x78},{0x7F,0x48,0x44,0x44,0x38},
    {0x38,0x44,0x44,0x44,0x20},{0x38,0x44,0x44,0x48,0x7F},
    {0x38,0x54,0x54,0x54,0x18},{0x08,0x7E,0x09,0x01,0x02},
    {0x0C,0x52,0x52,0x52,0x3E},{0x7F,0x08,0x04,0x04,0x78},
    {0x00,0x44,0x7D,0x40,0x00},{0x20,0x40,0x44,0x3D,0x00},
    {0x7F,0x10,0x28,0x44,0x00},{0x00,0x41,0x7F,0x40,0x00},
    {0x7C,0x04,0x18,0x04,0x78},{0x7C,0x08,0x04,0x04,0x78},
    {0x38,0x44,0x44,0x44,0x38},{0x7C,0x14,0x14,0x14,0x08},
    {0x08,0x14,0x14,0x18,0x7C},{0x7C,0x08,0x04,0x04,0x08},
    {0x48,0x54,0x54,0x54,0x20},{0x04,0x3F,0x44,0x40,0x20},
    {0x3C,0x40,0x40,0x20,0x7C},{0x1C,0x20,0x40,0x20,0x1C},
    {0x3C,0x40,0x30,0x40,0x3C},{0x44,0x28,0x10,0x28,0x44},
    {0x0C,0x50,0x50,0x50,0x3C},{0x44,0x64,0x54,0x4C,0x44}
};

static const uint8_t kQuestion[5] = {0x02,0x01,0x51,0x09,0x06};
static const uint8_t kPunctuation[5] = {0x00,0x00,0x5F,0x00,0x00};

typedef struct {
    uint32_t codepoint;
    uint16_t rows[16];
} cjk_glyph_t;

static const cjk_glyph_t kCjkGlyphs[] = {
    {0x5B8C, {0x0200,0xFFFC,0x8004,0x0008,0x3FE0,0x0000,0x0000,0xFFF8,
              0x0880,0x0880,0x0880,0x1088,0x1088,0x2088,0xC078,0x0000}},
    {0x6210, {0x0090,0x0080,0x7FFC,0x4080,0x4080,0x4088,0x7C88,0x4488,
              0x4450,0x4450,0x4424,0x5464,0x8894,0x810C,0x0204,0x0000}},
    {0x8FDB, {0x4120,0x2120,0x27F8,0x0120,0x0120,0xE120,0x2FFC,0x2120,
              0x2120,0x2220,0x2220,0x2420,0x5000,0x8FFC,0x0000,0x0000}},
    {0x5EA6, {0x0100,0x7FFC,0x4440,0x4440,0x7FF8,0x4440,0x4440,0x47C0,
              0x4000,0x5FE0,0x4820,0x8440,0x8380,0x0C60,0x701C,0x0000}},
    {0x63D2, {0x4078,0x4F80,0x4080,0xF080,0x5FFC,0x4080,0x5280,0x6CB8,
              0xC888,0x4888,0x4EB8,0x4888,0x4888,0x4FF8,0x8808,0x0000}},
    {0x4EF6, {0x1040,0x1240,0x2240,0x23F8,0x6440,0x6440,0xA840,0x2040,
              0x2FFC,0x2040,0x2040,0x2040,0x2040,0x2040,0x2040,0x0000}},
    {0x516C, {0x0840,0x0840,0x1020,0x2010,0x4208,0x8206,0x0400,0x0440,
              0x0820,0x1020,0x3FF0,0x1010,0x0000,0x0000,0x0000,0x0000}},
    {0x53F8, {0x0008,0x7FE8,0x0008,0x0008,0x1F88,0x1088,0x1088,0x1088,
              0x1088,0x1F88,0x1088,0x0028,0x0010,0x0000,0x0000,0x0000}}
};

/* Power, interface, and gamma values published by LCDWiki for the IPS panel
 * fitted to ES3C28P. Sleep-out, RGB565, MADCTL, inversion, and display-on are
 * handled by the component and the calls in display_init(). */
static const ili9341_lcd_init_cmd_t kEs3c28pLcdInit[] = {
    {0xCF, (uint8_t[]){0x00, 0xC1, 0x30}, 3, 0},
    {0xED, (uint8_t[]){0x64, 0x03, 0x12, 0x81}, 4, 0},
    {0xE8, (uint8_t[]){0x85, 0x00, 0x78}, 3, 0},
    {0xCB, (uint8_t[]){0x39, 0x2C, 0x00, 0x34, 0x02}, 5, 0},
    {0xF7, (uint8_t[]){0x20}, 1, 0},
    {0xEA, (uint8_t[]){0x00, 0x00}, 2, 0},
    {0xC0, (uint8_t[]){0x13}, 1, 0},
    {0xC1, (uint8_t[]){0x13}, 1, 0},
    {0xC5, (uint8_t[]){0x22, 0x35}, 2, 0},
    {0xC7, (uint8_t[]){0xBD}, 1, 0},
    {0xB6, (uint8_t[]){0x0A, 0xA2}, 2, 0},
    {0xF6, (uint8_t[]){0x01, 0x30}, 2, 0},
    {0xB1, (uint8_t[]){0x00, 0x1B}, 2, 0},
    {0xF2, (uint8_t[]){0x00}, 1, 0},
    {0x26, (uint8_t[]){0x01}, 1, 0},
    {0xE0, (uint8_t[]){0x0F, 0x35, 0x31, 0x0B, 0x0E, 0x06, 0x49, 0xA7,
                       0x33, 0x07, 0x0F, 0x03, 0x0C, 0x0A, 0x00}, 15, 0},
    {0xE1, (uint8_t[]){0x00, 0x0A, 0x0F, 0x04, 0x11, 0x08, 0x36, 0x58,
                       0x4D, 0x07, 0x10, 0x0C, 0x32, 0x34, 0x0F}, 15, 0},
};

static const ili9341_vendor_config_t kEs3c28pLcdVendorConfig = {
    .init_cmds = kEs3c28pLcdInit,
    .init_cmds_size = sizeof(kEs3c28pLcdInit) / sizeof(kEs3c28pLcdInit[0]),
};

static const uint8_t *ascii_glyph(char c)
{
    if (c >= '0' && c <= '9') return kDigits[c - '0'];
    if (c >= 'A' && c <= 'Z') return kUpper[c - 'A'];
    if (c >= 'a' && c <= 'z') return kLower[c - 'a'];
    if (c == ' ') return NULL;
    if (c == '.' || c == ':' || c == '-' || c == '_') return kPunctuation;
    return kQuestion;
}

static const cjk_glyph_t *cjk_glyph(uint32_t codepoint)
{
    for (size_t i = 0; i < sizeof(kCjkGlyphs) / sizeof(kCjkGlyphs[0]); ++i) {
        if (kCjkGlyphs[i].codepoint == codepoint) return &kCjkGlyphs[i];
    }
    return NULL;
}

static bool utf8_continuation(uint8_t byte)
{
    return (byte & 0xC0) == 0x80;
}

static size_t utf8_decode(const char *text, uint32_t *codepoint)
{
    const uint8_t first = (uint8_t)text[0];
    if (first < 0x80) { *codepoint = first; return 1; }
    if ((first & 0xE0) == 0xC0 && text[1] &&
        utf8_continuation((uint8_t)text[1])) {
        *codepoint = ((uint32_t)(first & 0x1F) << 6) | ((uint8_t)text[1] & 0x3F); return 2;
    }
    if ((first & 0xF0) == 0xE0 && text[1] && text[2] &&
        utf8_continuation((uint8_t)text[1]) && utf8_continuation((uint8_t)text[2])) {
        *codepoint = ((uint32_t)(first & 0x0F) << 12) |
                     (((uint8_t)text[1] & 0x3F) << 6) | ((uint8_t)text[2] & 0x3F); return 3;
    }
    if ((first & 0xF8) == 0xF0 && text[1] && text[2] && text[3] &&
        utf8_continuation((uint8_t)text[1]) && utf8_continuation((uint8_t)text[2]) &&
        utf8_continuation((uint8_t)text[3])) {
        *codepoint = ((uint32_t)(first & 0x07) << 18) |
                     (((uint8_t)text[1] & 0x3F) << 12) |
                     (((uint8_t)text[2] & 0x3F) << 6) | ((uint8_t)text[3] & 0x3F);
        return 4;
    }
    *codepoint = '?';
    return 1;
}

static int text_width_scaled(const char *text, int scale)
{
    int width = 0;
    for (size_t offset = 0; text[offset];) {
        uint32_t cp;
        offset += utf8_decode(text + offset, &cp);
        width += cjk_glyph(cp) ? 18 * scale : 6 * scale;
    }
    return width;
}

static int text_width(const char *text)
{
    return text_width_scaled(text, TEXT_SCALE);
}

static void copy_utf8_fitted(char *output, size_t capacity, const char *input,
                             int max_width, int scale)
{
    if (capacity == 0) return;
    output[0] = '\0';
    if (input == NULL) return;

    size_t source_offset = 0;
    size_t output_offset = 0;
    int width = 0;
    while (input[source_offset]) {
        uint32_t codepoint;
        const size_t bytes = utf8_decode(input + source_offset, &codepoint);
        const int glyph_width = cjk_glyph(codepoint) ? 18 * scale : 6 * scale;
        if (width + glyph_width > max_width || output_offset + bytes >= capacity) break;
        memcpy(output + output_offset, input + source_offset, bytes);
        output_offset += bytes;
        source_offset += bytes;
        width += glyph_width;
    }
    output[output_offset] = '\0';
}

static void fill_row(uint16_t *row, uint16_t color)
{
    for (int x = 0; x < LCD_WIDTH; ++x) row[x] = color;
}

static uint16_t color_for_lcd(uint16_t rgb565)
{
    /* esp_lcd_ili9341 1.2.0 queues the caller's bytes unchanged. ESP32-S3 is
     * little-endian, while ILI9341 expects the high RGB565 byte first. */
    return (uint16_t)((rgb565 << 8) | (rgb565 >> 8));
}

static void paint_ascii_row(uint16_t *row, int x, int y, int top, char c,
                            int scale, int clip_right, uint16_t color)
{
    const uint8_t *glyph = ascii_glyph(c);
    if (glyph == NULL) return;
    for (int sy = 0; sy < 7; ++sy) {
        if (y < top + sy * scale || y >= top + (sy + 1) * scale) continue;
        for (int sx = 0; sx < 5; ++sx) {
            if ((glyph[sx] & (1U << sy)) == 0) continue;
            for (int dx = 0; dx < scale; ++dx) {
                int px = x + sx * scale + dx;
                if (px >= 0 && px < LCD_WIDTH && px < clip_right) row[px] = color;
            }
        }
    }
}

static void paint_cjk_row(uint16_t *row, int x, int y, int top, const cjk_glyph_t *glyph,
                          int scale, int clip_right, uint16_t color)
{
    if (glyph == NULL) return;
    for (int sy = 0; sy < 16; ++sy) {
        if (y < top + sy * scale || y >= top + (sy + 1) * scale) continue;
        for (int sx = 0; sx < 16; ++sx) {
            if ((glyph->rows[sy] & (1U << (15 - sx))) == 0) continue;
            for (int dx = 0; dx < scale; ++dx) {
                int px = x + sx * scale + dx;
                if (px >= 0 && px < LCD_WIDTH && px < clip_right) row[px] = color;
            }
        }
    }
}

static void paint_text_row_at(uint16_t *row, const char *text, int y, int x,
                              int cjk_top, int ascii_top, int scale,
                              int clip_right, uint16_t color)
{
    for (size_t offset = 0; text[offset];) {
        uint32_t cp;
        offset += utf8_decode(text + offset, &cp);
        const cjk_glyph_t *cjk = cjk_glyph(cp);
        if (cjk) {
            paint_cjk_row(row, x, y, cjk_top, cjk, scale, clip_right, color);
            x += 18 * scale;
        } else {
            paint_ascii_row(row, x, y, ascii_top, (char)(cp < 0x80 ? cp : '?'),
                            scale, clip_right, color);
            x += 6 * scale;
        }
        if (x >= clip_right) break;
    }
}

static void paint_text_row(uint16_t *row, const char *text, int y, int x, uint16_t color)
{
    paint_text_row_at(row, text, y, x, TEXT_TOP, TEXT_TOP + 4, TEXT_SCALE,
                      LCD_WIDTH, color);
}

static void paint_rectangle_row(uint16_t *row, int y, int left, int top,
                                int right, int bottom, uint16_t color)
{
    if (y < top || y >= bottom) return;
    if (left < 0) left = 0;
    if (right > LCD_WIDTH) right = LCD_WIDTH;
    for (int x = left; x < right; ++x) row[x] = color;
}

static bool lcd_color_transfer_done(esp_lcd_panel_io_handle_t panel_io,
                                    esp_lcd_panel_io_event_data_t *event_data,
                                    void *user_context)
{
    (void)panel_io;
    (void)event_data;
    (void)user_context;
    BaseType_t task_woken = pdFALSE;
    if (s_lcd_done) xSemaphoreGiveFromISR(s_lcd_done, &task_woken);
    return task_woken == pdTRUE;
}

static void paint_project_list_row(uint16_t *row, int y, const project_snapshot_t *snapshot)
{
    const size_t row_index = (size_t)(y / PROJECT_ROW_HEIGHT);
    const int row_top = (int)row_index * PROJECT_ROW_HEIGHT;
    const uint16_t separator = color_for_lcd(0x2188); /* slate */
    if (y == row_top + PROJECT_ROW_HEIGHT - 1) fill_row(row, separator);

    /* Keep all six project rows. When the host reports more projects than fit,
     * use the otherwise empty 7-pixel strip above the first status badge. */
    if (row_index == 0 && snapshot->project_total > (int)snapshot->project_count) {
        char total_label[24];
        snprintf(total_label, sizeof(total_label), "%u/%d",
                 (unsigned)snapshot->project_count, snapshot->project_total);
        const int total_x = LCD_WIDTH - 2 - text_width_scaled(total_label, 1);
        paint_text_row_at(row, total_label, y, total_x, 0, 0, 1,
                          LCD_WIDTH, color_for_lcd(0x94B6));
    }
    if (row_index >= snapshot->project_count) return;

    const project_row_t *project = &snapshot->projects[row_index];
    const uint16_t name_color = color_for_lcd(0xE71C); /* near-white */
    const uint16_t status_color = color_for_lcd(project->completed ? 0x262B : 0xEA28);
    const uint16_t status_text_color = color_for_lcd(0xFFFF);
    const int badge_top = row_top + 8;
    const int badge_bottom = row_top + 32;
    paint_rectangle_row(row, y, PROJECT_STATUS_LEFT, badge_top,
                        PROJECT_STATUS_RIGHT, badge_bottom, status_color);
    paint_text_row_at(row, project->name, y, PROJECT_NAME_X,
                      row_top + 12, row_top + 16, PROJECT_NAME_SCALE,
                      PROJECT_NAME_RIGHT, name_color);

    const char *label = project->completed ? "DONE" : "RUN";
    const int label_width = text_width_scaled(label, PROJECT_STATUS_SCALE);
    const int label_x = PROJECT_STATUS_LEFT +
                        (PROJECT_STATUS_RIGHT - PROJECT_STATUS_LEFT - label_width) / 2;
    paint_text_row_at(row, label, y, label_x, row_top + 4, row_top + 13,
                      PROJECT_STATUS_SCALE, PROJECT_STATUS_RIGHT, status_text_color);

}

static void render_frame(void)
{
    if (s_panel == NULL || s_state_mutex == NULL || s_lcd_done == NULL) return;
    expire_stale_project_snapshot();
    char text[TEXT_CAPACITY];
    uint16_t background;
    uint16_t foreground;
    int scroll_x;
    bool completion;
    bool host_offline;
    xSemaphoreTake(s_state_mutex, portMAX_DELAY);
    strncpy(text, s_text, sizeof(text) - 1);
    text[sizeof(text) - 1] = '\0';
    background = s_background;
    foreground = s_foreground;
    scroll_x = s_scroll_x;
    completion = s_completion;
    host_offline = s_host_offline;
    s_render_projects = s_projects;
    xSemaphoreGive(s_state_mutex);

    const bool project_view = !host_offline && s_render_projects.snapshot_active &&
                               (s_render_projects.project_count > 0 ||
                                s_render_projects.project_total > 0);
    if (host_offline) {
        snprintf(text, sizeof(text), "HOST OFFLINE");
        background = 0x2104;
        foreground = 0xFFFF;
        completion = false;
    } else if (s_render_projects.snapshot_active && !project_view) {
        snprintf(text, sizeof(text), "Codex ready");
        background = 0x0884;
        foreground = 0xE71C;
        completion = false;
    }
    const int width = text_width(text);
    const int x = completion ? scroll_x : (LCD_WIDTH - width) / 2;
    if (project_view) background = 0x0884;
    background = color_for_lcd(background);
    foreground = color_for_lcd(foreground);
    for (int top = 0; top < LCD_HEIGHT; top += LCD_DRAW_LINES) {
        const int bottom = (top + LCD_DRAW_LINES < LCD_HEIGHT) ? top + LCD_DRAW_LINES : LCD_HEIGHT;
        for (int y = top; y < bottom; ++y) {
            uint16_t *row = s_lcd_buffer + (y - top) * LCD_WIDTH;
            fill_row(row, background);
            if (project_view) {
                paint_project_list_row(row, y, &s_render_projects);
            } else {
                paint_text_row(row, text, y, x, foreground);
            }
        }
        esp_err_t err = esp_lcd_panel_draw_bitmap(s_panel, 0, top, LCD_WIDTH, bottom, s_lcd_buffer);
        if (err != ESP_OK) {
            ESP_LOGE(TAG, "LCD draw failed: %s", esp_err_to_name(err));
            return;
        }
        /* SPI color writes use DMA. Do not recycle the shared buffer until the
         * driver's completion callback confirms that this band was sent. */
        xSemaphoreTake(s_lcd_done, portMAX_DELAY);
    }

    if (completion && !project_view) {
        xSemaphoreTake(s_state_mutex, portMAX_DELAY);
        s_scroll_x -= 3;
        if (s_scroll_x < -width - 20) s_scroll_x = LCD_WIDTH;
        xSemaphoreGive(s_state_mutex);
    }
}

static void display_task(void *argument)
{
    (void)argument;
    while (true) {
        render_frame();
        vTaskDelay(pdMS_TO_TICKS(FRAME_PERIOD_MS));
    }
}

static int hex_value(char c)
{
    if (c >= '0' && c <= '9') return c - '0';
    if (c >= 'a' && c <= 'f') return c - 'a' + 10;
    if (c >= 'A' && c <= 'F') return c - 'A' + 10;
    return -1;
}

static uint16_t color_from_hex(const char *value, uint16_t fallback)
{
    if (value == NULL || value[0] != '#' || strlen(value) < 7) return fallback;
    int r0 = hex_value(value[1]), r1 = hex_value(value[2]);
    int g0 = hex_value(value[3]), g1 = hex_value(value[4]);
    int b0 = hex_value(value[5]), b1 = hex_value(value[6]);
    if (r0 < 0 || r1 < 0 || g0 < 0 || g1 < 0 || b0 < 0 || b1 < 0) return fallback;
    const uint8_t r = (uint8_t)((r0 << 4) | r1);
    const uint8_t g = (uint8_t)((g0 << 4) | g1);
    const uint8_t b = (uint8_t)((b0 << 4) | b1);
    return (uint16_t)(((r & 0xF8) << 8) | ((g & 0xFC) << 3) | (b >> 3));
}

static bool copy_json_string(const cJSON *root, const char *key, char *output, size_t capacity)
{
    const cJSON *item = cJSON_GetObjectItemCaseSensitive(root, key);
    if (!cJSON_IsString(item) || item->valuestring == NULL || capacity == 0) return false;
    snprintf(output, capacity, "%s", item->valuestring);
    return true;
}

static void set_completion(const char *project, const char *message, const char *background, const char *foreground)
{
    char display_name[PROJECT_NAME_CAPACITY];
    copy_utf8_fitted(display_name, sizeof(display_name), project[0] ? project : "Codex",
                     PROJECT_NAME_RIGHT - PROJECT_NAME_X, PROJECT_NAME_SCALE);
    xSemaphoreTake(s_state_mutex, portMAX_DELAY);
    if (s_projects.snapshot_active) {
        size_t index = 0;
        while (index < s_projects.project_count &&
               strcmp(s_projects.projects[index].name, display_name) != 0) {
            ++index;
        }
        if (index == s_projects.project_count && index < PROJECT_ROW_COUNT) {
            snprintf(s_projects.projects[index].name,
                     sizeof(s_projects.projects[index].name), "%s", display_name);
            s_projects.projects[index].completed = true;
            ++s_projects.project_count;
            if (s_projects.project_total < (int)s_projects.project_count) {
                s_projects.project_total = (int)s_projects.project_count;
            }
        } else if (index < s_projects.project_count) {
            s_projects.projects[index].completed = true;
        }
        s_completion = false;
    } else {
        snprintf(s_text, sizeof(s_text), "%s  %s",
                 project[0] ? project : "Codex",
                 message[0] ? message : "\xE5\xAE\x8C\xE6\x88\x90");
        s_background = color_from_hex(background, 0x05E0);
        s_foreground = color_from_hex(foreground, 0xFFFF);
        s_scroll_x = LCD_WIDTH;
        s_completion = true;
    }
    xSemaphoreGive(s_state_mutex);
    if (s_audio_ready && s_audio_event) xSemaphoreGive(s_audio_event);
    ESP_LOGI(TAG, "completion received: %s", project[0] ? project : "Codex");
}

static void set_project_snapshot(const project_row_t *projects, size_t count, int total)
{
    if (count > PROJECT_ROW_COUNT) count = PROJECT_ROW_COUNT;
    const int effective_total = total < (int)count ? (int)count : total;
    const int64_t received_us = esp_timer_get_time();
    xSemaphoreTake(s_state_mutex, portMAX_DELAY);
    memset(&s_projects, 0, sizeof(s_projects));
    s_projects.snapshot_active = true;
    s_projects.project_count = count;
    s_projects.project_total = effective_total;
    if (count > 0) memcpy(s_projects.projects, projects, count * sizeof(projects[0]));
    s_completion = false;
    s_last_project_snapshot_us = received_us;
    s_host_offline = false;
    xSemaphoreGive(s_state_mutex);
    ESP_LOGI(TAG, "project snapshot received: showing %u of %d",
             (unsigned)count, effective_total);
}

static bool handle_project_snapshot(const cJSON *root)
{
    const cJSON *total_item = cJSON_GetObjectItemCaseSensitive(root, "total");
    const cJSON *projects_item = cJSON_GetObjectItemCaseSensitive(root, "projects");
    if (!cJSON_IsNumber(total_item) || total_item->valuedouble < 0.0 ||
        total_item->valuedouble > 2147483647.0 || !cJSON_IsArray(projects_item)) {
        return false;
    }

    const int total = (int)total_item->valuedouble;
    const int supplied_count = cJSON_GetArraySize(projects_item);
    if ((double)total != total_item->valuedouble || supplied_count < 0 ||
        supplied_count > PROJECT_ROW_COUNT || total < supplied_count) {
        return false;
    }

    project_row_t projects[PROJECT_ROW_COUNT] = {0};
    size_t count = 0;
    const cJSON *item = NULL;
    cJSON_ArrayForEach(item, projects_item) {
        if (!cJSON_IsObject(item)) return false;
        const cJSON *name_item = cJSON_GetObjectItemCaseSensitive(item, "name");
        const cJSON *status_item = cJSON_GetObjectItemCaseSensitive(item, "status");
        if (!cJSON_IsString(name_item) || name_item->valuestring == NULL ||
            !cJSON_IsString(status_item) || status_item->valuestring == NULL) {
            return false;
        }
        const char *name = name_item->valuestring[0] ? name_item->valuestring : "Codex";
        copy_utf8_fitted(projects[count].name, sizeof(projects[count].name), name,
                         PROJECT_NAME_RIGHT - PROJECT_NAME_X, PROJECT_NAME_SCALE);
        projects[count].completed = strcmp(status_item->valuestring, "completed") == 0;
        ++count;
    }
    set_project_snapshot(projects, count, total);
    return true;
}

static void handle_message(const char *line)
{
    char type[32], status[32], project[PROJECT_CAPACITY], message[MESSAGE_CAPACITY];
    char background[16], foreground[16];
    cJSON *root = cJSON_ParseWithOpts(line, NULL, true);
    if (!cJSON_IsObject(root)) {
        cJSON_Delete(root);
        return;
    }
    const cJSON *version = cJSON_GetObjectItemCaseSensitive(root, "version");
    if (!cJSON_IsNumber(version) || version->valuedouble != 1.0 ||
        !copy_json_string(root, "type", type, sizeof(type))) {
        cJSON_Delete(root);
        return;
    }
    if (strcmp(type, "project_snapshot") == 0) {
        if (!handle_project_snapshot(root)) {
            ESP_LOGW(TAG, "invalid project snapshot ignored");
        }
        cJSON_Delete(root);
        return;
    }
    if (strcmp(type, "completion") != 0 ||
        !copy_json_string(root, "status", status, sizeof(status)) ||
        strcmp(status, "completed") != 0) {
        cJSON_Delete(root);
        return;
    }
    if (!copy_json_string(root, "project", project, sizeof(project))) strcpy(project, "Codex");
    if (!copy_json_string(root, "message", message, sizeof(message))) strcpy(message, "\xE5\xAE\x8C\xE6\x88\x90");
    if (!copy_json_string(root, "background", background, sizeof(background))) strcpy(background, "#16A34A");
    if (!copy_json_string(root, "foreground", foreground, sizeof(foreground))) strcpy(foreground, "#FFFFFF");
    set_completion(project, message, background, foreground);
    cJSON_Delete(root);
}

static void serial_task(void *argument)
{
    (void)argument;
    size_t length = 0;
    bool discard_until_newline = false;
    uint8_t buffer[64];
    while (true) {
        int received = usb_serial_jtag_read_bytes(buffer, sizeof(buffer), pdMS_TO_TICKS(100));
        if (received <= 0) continue;
        for (int i = 0; i < received; ++i) {
            char c = (char)buffer[i];
            if (c == '\n') {
                if (!discard_until_newline && length) {
                    s_rx_line[length] = '\0';
                    handle_message(s_rx_line);
                }
                length = 0;
                discard_until_newline = false;
            } else if (c != '\r' && !discard_until_newline) {
                if (length + 1 < sizeof(s_rx_line)) {
                    s_rx_line[length++] = c;
                } else {
                    length = 0;
                    discard_until_newline = true;
                    ESP_LOGW(TAG, "discarding oversized serial message");
                }
            }
        }
    }
}

static esp_err_t codec_write(i2c_master_dev_handle_t device, uint8_t reg, uint8_t value)
{
    uint8_t data[2] = {reg, value};
    return i2c_master_transmit(device, data, sizeof(data), pdMS_TO_TICKS(1000));
}

static esp_err_t codec_read(i2c_master_dev_handle_t device, uint8_t reg, uint8_t *value)
{
    return i2c_master_transmit_receive(device, &reg, 1, value, 1, pdMS_TO_TICKS(1000));
}

static esp_err_t audio_init(void)
{
    gpio_config_t amp = {
        .pin_bit_mask = 1ULL << AUDIO_ENABLE,
        .mode = GPIO_MODE_OUTPUT,
    };
    ESP_RETURN_ON_ERROR(gpio_config(&amp), TAG, "audio enable gpio");
    ESP_RETURN_ON_ERROR(gpio_set_level(AUDIO_ENABLE, 1), TAG, "audio disable during setup");

    i2c_master_bus_config_t bus_config = {
        .i2c_port = I2C_NUM_0,
        .sda_io_num = I2C_SDA,
        .scl_io_num = I2C_SCL,
        .clk_source = I2C_CLK_SRC_DEFAULT,
        .glitch_ignore_cnt = 7,
        .flags.enable_internal_pullup = true,
    };
    i2c_master_bus_handle_t bus;
    ESP_RETURN_ON_ERROR(i2c_new_master_bus(&bus_config, &bus), TAG, "i2c bus");
    i2c_device_config_t device_config = {
        .dev_addr_length = I2C_ADDR_BIT_LEN_7,
        .device_address = ES8311_ADDRESS,
        .scl_speed_hz = 400000,
    };
    i2c_master_dev_handle_t codec;
    ESP_RETURN_ON_ERROR(i2c_master_bus_add_device(bus, &device_config, &codec), TAG, "es8311 device");

    /* ES8311 setup from the ES3C28P vendor example: 44.1 kHz, 16-bit I2S. */
    ESP_RETURN_ON_ERROR(codec_write(codec, 0x00, 0x1F), TAG, "codec reset");
    vTaskDelay(pdMS_TO_TICKS(20));
    ESP_RETURN_ON_ERROR(codec_write(codec, 0x00, 0x00), TAG, "codec reset clear");
    ESP_RETURN_ON_ERROR(codec_write(codec, 0x00, 0x80), TAG, "codec power");
    ESP_RETURN_ON_ERROR(codec_write(codec, 0x01, 0x3F), TAG, "codec clocks");
    ESP_RETURN_ON_ERROR(codec_write(codec, 0x02, 0x00), TAG, "codec clock div");
    ESP_RETURN_ON_ERROR(codec_write(codec, 0x03, 0x10), TAG, "codec adc osr");
    ESP_RETURN_ON_ERROR(codec_write(codec, 0x04, 0x10), TAG, "codec dac osr");
    ESP_RETURN_ON_ERROR(codec_write(codec, 0x05, 0x00), TAG, "codec clock div");
    uint8_t reg06 = 0;
    ESP_RETURN_ON_ERROR(codec_read(codec, 0x06, &reg06), TAG, "codec bclk read");
    ESP_RETURN_ON_ERROR(codec_write(codec, 0x06, (uint8_t)((reg06 & 0xE0) | 0x03)), TAG, "codec bclk");
    uint8_t reg07 = 0;
    ESP_RETURN_ON_ERROR(codec_read(codec, 0x07, &reg07), TAG, "codec lrck read");
    ESP_RETURN_ON_ERROR(codec_write(codec, 0x07, (uint8_t)(reg07 & 0xC0)), TAG, "codec lrck");
    ESP_RETURN_ON_ERROR(codec_write(codec, 0x08, 0xFF), TAG, "codec lrck div");
    ESP_RETURN_ON_ERROR(codec_write(codec, 0x09, 0x0C), TAG, "codec input format");
    ESP_RETURN_ON_ERROR(codec_write(codec, 0x0A, 0x0C), TAG, "codec output format");
    ESP_RETURN_ON_ERROR(codec_write(codec, 0x0D, 0x01), TAG, "codec analog power");
    ESP_RETURN_ON_ERROR(codec_write(codec, 0x0E, 0x02), TAG, "codec pga");
    ESP_RETURN_ON_ERROR(codec_write(codec, 0x12, 0x00), TAG, "codec dac power");
    ESP_RETURN_ON_ERROR(codec_write(codec, 0x13, 0x10), TAG, "codec output");
    ESP_RETURN_ON_ERROR(codec_write(codec, 0x1C, 0x6A), TAG, "codec adc");
    ESP_RETURN_ON_ERROR(codec_write(codec, 0x37, 0x08), TAG, "codec dac eq");
    ESP_RETURN_ON_ERROR(codec_write(codec, 0x32, 0xE5), TAG, "codec volume");
    ESP_RETURN_ON_ERROR(codec_write(codec, 0x31, 0x00), TAG, "codec unmute");

    i2s_config_t i2s_config = {
        .mode = I2S_MODE_MASTER | I2S_MODE_TX,
        .sample_rate = AUDIO_SAMPLE_RATE,
        .bits_per_sample = I2S_BITS_PER_SAMPLE_16BIT,
        .channel_format = I2S_CHANNEL_FMT_RIGHT_LEFT,
        .communication_format = I2S_COMM_FORMAT_STAND_I2S,
        .intr_alloc_flags = ESP_INTR_FLAG_LEVEL1,
        .dma_buf_count = 8,
        .dma_buf_len = 256,
        .use_apll = true,
        .tx_desc_auto_clear = true,
        .fixed_mclk = AUDIO_MCLK,
    };
    i2s_pin_config_t pins = {
        .mck_io_num = I2S_MCLK,
        .bck_io_num = I2S_BCLK,
        .ws_io_num = I2S_LRCK,
        .data_out_num = I2S_DOUT,
        .data_in_num = I2S_PIN_NO_CHANGE,
    };
    ESP_RETURN_ON_ERROR(i2s_driver_install(I2S_NUM_0, &i2s_config, 0, NULL), TAG, "i2s install");
    ESP_RETURN_ON_ERROR(i2s_set_pin(I2S_NUM_0, &pins), TAG, "i2s pins");
    ESP_RETURN_ON_ERROR(gpio_set_level(AUDIO_ENABLE, 0), TAG, "audio enable");
    s_audio_ready = true;
    ESP_LOGI(TAG, "ES8311 audio ready");
    return ESP_OK;
}

static void play_tone(uint16_t frequency, uint16_t milliseconds)
{
    if (!s_audio_ready) return;
    uint32_t phase = 0;
    const uint32_t increment = (uint32_t)(((uint64_t)frequency << 32) / AUDIO_SAMPLE_RATE);
    uint8_t buffer[1024];
    const uint32_t total_frames = ((uint32_t)milliseconds * AUDIO_SAMPLE_RATE) / 1000;
    uint32_t frames_done = 0;
    while (frames_done < total_frames) {
        uint32_t frames = (total_frames - frames_done > 256) ? 256 : total_frames - frames_done;
        int16_t *samples = (int16_t *)buffer;
        for (uint32_t i = 0; i < frames; ++i) {
            phase += increment;
            int16_t value = (phase & 0x80000000U) ? 5000 : -5000;
            samples[i * 2] = value;
            samples[i * 2 + 1] = value;
        }
        size_t written = 0;
        (void)i2s_write(I2S_NUM_0, buffer, frames * 4, &written, portMAX_DELAY);
        frames_done += frames;
    }
}

static void audio_task(void *argument)
{
    (void)argument;
    const uint16_t notes[] = {523, 659, 784, 1047, 784, 1047};
    while (true) {
        if (xSemaphoreTake(s_audio_event, portMAX_DELAY) == pdTRUE) {
            for (size_t i = 0; i < sizeof(notes) / sizeof(notes[0]); ++i) {
                play_tone(notes[i], 150);
                vTaskDelay(pdMS_TO_TICKS(20));
            }
        }
    }
}

static esp_err_t display_init(void)
{
    spi_bus_config_t bus_config = ILI9341_PANEL_BUS_SPI_CONFIG(
        LCD_SCLK, LCD_MOSI, LCD_WIDTH * LCD_DRAW_LINES * sizeof(uint16_t)
    );
    bus_config.miso_io_num = LCD_MISO;
    ESP_RETURN_ON_ERROR(spi_bus_initialize(SPI2_HOST, &bus_config, SPI_DMA_CH_AUTO), TAG, "lcd spi bus");
    esp_lcd_panel_io_spi_config_t io_config = ILI9341_PANEL_IO_SPI_CONFIG(
        LCD_CS, LCD_DC, lcd_color_transfer_done, NULL
    );
    io_config.pclk_hz = 40 * 1000 * 1000;
    esp_lcd_panel_io_handle_t io;
    ESP_RETURN_ON_ERROR(esp_lcd_new_panel_io_spi((esp_lcd_spi_bus_handle_t)SPI2_HOST, &io_config, &io), TAG, "lcd io");
    esp_lcd_panel_dev_config_t panel_config = {
        .reset_gpio_num = -1,
        .rgb_ele_order = LCD_RGB_ELEMENT_ORDER_BGR,
        /* Byte order is handled explicitly by color_for_lcd(). */
        .data_endian = LCD_RGB_DATA_ENDIAN_LITTLE,
        .bits_per_pixel = 16,
        .vendor_config = (void *)&kEs3c28pLcdVendorConfig,
    };
    ESP_RETURN_ON_ERROR(esp_lcd_new_panel_ili9341(io, &panel_config, &s_panel), TAG, "lcd panel");
    ESP_RETURN_ON_ERROR(esp_lcd_panel_reset(s_panel), TAG, "lcd reset");
    ESP_RETURN_ON_ERROR(esp_lcd_panel_init(s_panel), TAG, "lcd init");
    ESP_RETURN_ON_ERROR(esp_lcd_panel_invert_color(s_panel, true), TAG, "lcd invert colors");
    ESP_RETURN_ON_ERROR(esp_lcd_panel_swap_xy(s_panel, true), TAG, "lcd landscape");
    ESP_RETURN_ON_ERROR(esp_lcd_panel_mirror(s_panel, false, true), TAG, "lcd mirror");
    ESP_RETURN_ON_ERROR(esp_lcd_panel_disp_on_off(s_panel, true), TAG, "lcd on");
    gpio_config_t backlight = {
        .pin_bit_mask = 1ULL << LCD_BACKLIGHT,
        .mode = GPIO_MODE_OUTPUT,
    };
    ESP_RETURN_ON_ERROR(gpio_config(&backlight), TAG, "backlight gpio");
    ESP_RETURN_ON_ERROR(gpio_set_level(LCD_BACKLIGHT, 1), TAG, "backlight on");
    return ESP_OK;
}

void app_main(void)
{
    s_state_mutex = xSemaphoreCreateMutex();
    s_audio_event = xSemaphoreCreateCounting(AUDIO_EVENT_QUEUE_LENGTH, 0);
    s_lcd_done = xSemaphoreCreateBinary();
    if (!s_state_mutex || !s_audio_event || !s_lcd_done) {
        ESP_LOGE(TAG, "not enough memory for synchronization");
        return;
    }
    const bool display_ready = display_init() == ESP_OK;
    if (!display_ready) {
        s_panel = NULL;
        ESP_LOGE(TAG, "display initialization failed");
    }
    if (audio_init() != ESP_OK) ESP_LOGW(TAG, "audio initialization failed; display/serial remain available");
    if (s_audio_ready && xTaskCreate(audio_task, "codex_audio", AUDIO_TASK_STACK_SIZE, NULL, 4, NULL) != pdPASS) {
        s_audio_ready = false;
        ESP_LOGE(TAG, "could not create audio task");
    }
    if (display_ready && xTaskCreate(display_task, "codex_display", DISPLAY_TASK_STACK_SIZE, NULL, 3, NULL) != pdPASS) {
        ESP_LOGE(TAG, "could not create display task");
    }
    if (!usb_serial_jtag_is_driver_installed()) {
        usb_serial_jtag_driver_config_t usb_config = USB_SERIAL_JTAG_DRIVER_CONFIG_DEFAULT();
        usb_config.rx_buffer_size = RX_LINE_CAPACITY;
        usb_config.tx_buffer_size = 256;
        ESP_ERROR_CHECK(usb_serial_jtag_driver_install(&usb_config));
    }
    /* CONFIG_ESP_CONSOLE_USB_SERIAL_JTAG initially binds stdio to the ROM-style
     * non-driver VFS. Switch it after installing the interrupt-driven driver so
     * logs and protocol RX share one implementation safely. */
    usb_serial_jtag_vfs_use_driver();
    if (xTaskCreate(serial_task, "codex_serial", SERIAL_TASK_STACK_SIZE, NULL, 5, NULL) != pdPASS) {
        ESP_LOGE(TAG, "could not create serial task");
        return;
    }
    ESP_LOGI(TAG, "ready: waiting for completion JSON over USB Serial/JTAG");
}
