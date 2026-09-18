#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "bsp/m5stack_core_s3.h"
#include "driver/usb_serial_jtag.h"
#include "esp_heap_caps.h"
#include "esp_lcd_panel_ops.h"
#include "esp_log.h"
#include "freertos/FreeRTOS.h"
#include "freertos/task.h"

#define RX_LINE_CAPACITY 768
#define PROJECT_CAPACITY 160
#define TEXT_COLOR 0xFFFF
#define READY_BACKGROUND 0x39E7
#define COMPLETE_BACKGROUND 0x05E0

static const char *TAG = "codex_finish";
static esp_lcd_panel_handle_t s_panel;
static esp_lcd_panel_io_handle_t s_panel_io;

/* Compact 5x7 ASCII font for the readable part of a project name. */
static const uint8_t kDigits[10][5] = {
    {0x3E, 0x51, 0x49, 0x45, 0x3E}, {0x00, 0x42, 0x7F, 0x40, 0x00},
    {0x42, 0x61, 0x51, 0x49, 0x46}, {0x21, 0x41, 0x45, 0x4B, 0x31},
    {0x18, 0x14, 0x12, 0x7F, 0x10}, {0x27, 0x45, 0x45, 0x45, 0x39},
    {0x3C, 0x4A, 0x49, 0x49, 0x30}, {0x01, 0x71, 0x09, 0x05, 0x03},
    {0x36, 0x49, 0x49, 0x49, 0x36}, {0x06, 0x49, 0x49, 0x29, 0x1E},
};

static const uint8_t kUppercase[26][5] = {
    {0x7E, 0x11, 0x11, 0x11, 0x7E}, {0x7F, 0x49, 0x49, 0x49, 0x36},
    {0x3E, 0x41, 0x41, 0x41, 0x22}, {0x7F, 0x41, 0x41, 0x22, 0x1C},
    {0x7F, 0x49, 0x49, 0x49, 0x41}, {0x7F, 0x09, 0x09, 0x09, 0x01},
    {0x3E, 0x41, 0x49, 0x49, 0x7A}, {0x7F, 0x08, 0x08, 0x08, 0x7F},
    {0x00, 0x41, 0x7F, 0x41, 0x00}, {0x20, 0x40, 0x41, 0x3F, 0x01},
    {0x7F, 0x08, 0x14, 0x22, 0x41}, {0x7F, 0x40, 0x40, 0x40, 0x40},
    {0x7F, 0x02, 0x0C, 0x02, 0x7F}, {0x7F, 0x04, 0x08, 0x10, 0x7F},
    {0x3E, 0x41, 0x41, 0x41, 0x3E}, {0x7F, 0x09, 0x09, 0x09, 0x06},
    {0x3E, 0x41, 0x51, 0x21, 0x5E}, {0x7F, 0x09, 0x19, 0x29, 0x46},
    {0x46, 0x49, 0x49, 0x49, 0x31}, {0x01, 0x01, 0x7F, 0x01, 0x01},
    {0x3F, 0x40, 0x40, 0x40, 0x3F}, {0x1F, 0x20, 0x40, 0x20, 0x1F},
    {0x7F, 0x20, 0x18, 0x20, 0x7F}, {0x63, 0x14, 0x08, 0x14, 0x63},
    {0x07, 0x08, 0x70, 0x08, 0x07}, {0x61, 0x51, 0x49, 0x45, 0x43},
};

static const uint8_t kLowercase[26][5] = {
    {0x20, 0x54, 0x54, 0x54, 0x78}, {0x7F, 0x48, 0x44, 0x44, 0x38},
    {0x38, 0x44, 0x44, 0x44, 0x20}, {0x38, 0x44, 0x44, 0x48, 0x7F},
    {0x38, 0x54, 0x54, 0x54, 0x18}, {0x08, 0x7E, 0x09, 0x01, 0x02},
    {0x0C, 0x52, 0x52, 0x52, 0x3E}, {0x7F, 0x08, 0x04, 0x04, 0x78},
    {0x00, 0x44, 0x7D, 0x40, 0x00}, {0x20, 0x40, 0x44, 0x3D, 0x00},
    {0x7F, 0x10, 0x28, 0x44, 0x00}, {0x00, 0x41, 0x7F, 0x40, 0x00},
    {0x7C, 0x04, 0x18, 0x04, 0x78}, {0x7C, 0x08, 0x04, 0x04, 0x78},
    {0x38, 0x44, 0x44, 0x44, 0x38}, {0x7C, 0x14, 0x14, 0x14, 0x08},
    {0x08, 0x14, 0x14, 0x18, 0x7C}, {0x7C, 0x08, 0x04, 0x04, 0x08},
    {0x48, 0x54, 0x54, 0x54, 0x20}, {0x04, 0x3F, 0x44, 0x40, 0x20},
    {0x3C, 0x40, 0x40, 0x20, 0x7C}, {0x1C, 0x20, 0x40, 0x20, 0x1C},
    {0x3C, 0x40, 0x30, 0x40, 0x3C}, {0x44, 0x28, 0x10, 0x28, 0x44},
    {0x0C, 0x50, 0x50, 0x50, 0x3C}, {0x44, 0x64, 0x54, 0x4C, 0x44},
};

static const uint8_t kQuestion[5] = {0x02, 0x01, 0x51, 0x09, 0x06};
static const uint8_t kDash[5] = {0x08, 0x08, 0x08, 0x08, 0x08};
static const uint8_t kDot[5] = {0x00, 0x60, 0x60, 0x00, 0x00};
static const uint8_t kColon[5] = {0x00, 0x36, 0x36, 0x00, 0x00};

typedef struct {
    uint32_t codepoint;
    uint16_t rows[16];
} cjk_glyph_t;

/* Includes 完成 and the Chinese characters in the current workspace name. */
static const cjk_glyph_t kCjkGlyphs[] = {
    {0x5B8C, {0x07E0, 0x0810, 0x1FF8, 0x0810, 0x0810, 0x0FF0, 0x0080, 0x07E0,
              0x0810, 0x0810, 0x0FF0, 0x0420, 0x0810, 0x1008, 0x3FFC, 0x0000}},
    {0x6210, {0x0020, 0x0070, 0x00E0, 0x0010, 0x1FFE, 0x0010, 0x07F0, 0x0410,
              0x0810, 0x1010, 0x2010, 0x3FF0, 0x0010, 0x0010, 0x000E, 0x0000}},
    {0x8FDB, {0x0008, 0x0018, 0x0038, 0x0008, 0x03FE, 0x0208, 0x0208, 0x03FE,
              0x0208, 0x0208, 0x03FE, 0x0000, 0x0008, 0x0018, 0x0030, 0x0060}},
    {0x5EA6, {0x0100, 0x03F8, 0x0100, 0x1FFE, 0x1002, 0x13F2, 0x1202, 0x13F2,
              0x1202, 0x13F2, 0x1002, 0x1FFE, 0x0400, 0x0C00, 0x1200, 0x01FE}},
    {0x63D2, {0x0200, 0x1200, 0x13FC, 0x1200, 0x13FC, 0x0200, 0x03F8, 0x0208,
              0x03F8, 0x0208, 0x03F8, 0x0208, 0x03F8, 0x0208, 0x0208, 0x0000}},
    {0x4EF6, {0x0400, 0x0C00, 0x1FFC, 0x0400, 0x07F0, 0x0440, 0x0440, 0x1FFC,
              0x0440, 0x0440, 0x07F0, 0x0440, 0x0440, 0x0440, 0x0440, 0x0000}},
};

static const uint8_t *ascii_columns(char character)
{
    if (character >= '0' && character <= '9') {
        return kDigits[(unsigned int)(character - '0')];
    }
    if (character >= 'A' && character <= 'Z') {
        return kUppercase[(unsigned int)(character - 'A')];
    }
    if (character >= 'a' && character <= 'z') {
        return kLowercase[(unsigned int)(character - 'a')];
    }
    switch (character) {
    case '-': return kDash;
    case '.': return kDot;
    case ':': return kColon;
    case '?': return kQuestion;
    default: return NULL;
    }
}

static const cjk_glyph_t *find_cjk_glyph(uint32_t codepoint)
{
    for (size_t index = 0; index < sizeof(kCjkGlyphs) / sizeof(kCjkGlyphs[0]); ++index) {
        if (kCjkGlyphs[index].codepoint == codepoint) {
            return &kCjkGlyphs[index];
        }
    }
    return NULL;
}

static void fill_row(uint16_t *row, uint16_t color)
{
    for (int x = 0; x < BSP_LCD_H_RES; ++x) {
        row[x] = color;
    }
}

static void paint_ascii_row(
    uint16_t *row,
    int x,
    int screen_y,
    int top_y,
    char character,
    int scale,
    uint16_t color
)
{
    const uint8_t *columns = ascii_columns(character);
    if (columns == NULL) {
        columns = kQuestion;
    }
    for (int source_y = 0; source_y < 7; ++source_y) {
        if (screen_y < top_y + source_y * scale || screen_y >= top_y + (source_y + 1) * scale) {
            continue;
        }
        for (int column = 0; column < 5; ++column) {
            if ((columns[column] & (1U << source_y)) == 0) {
                continue;
            }
            for (int dx = 0; dx < scale; ++dx) {
                const int pixel_x = x + column * scale + dx;
                if (pixel_x >= 0 && pixel_x < BSP_LCD_H_RES) {
                    row[pixel_x] = color;
                }
            }
        }
    }
}

static void paint_cjk_row(
    uint16_t *row,
    int x,
    int screen_y,
    int top_y,
    const cjk_glyph_t *glyph,
    int scale,
    uint16_t color
)
{
    if (glyph == NULL) {
        return;
    }
    for (int source_y = 0; source_y < 16; ++source_y) {
        if (screen_y < top_y + source_y * scale || screen_y >= top_y + (source_y + 1) * scale) {
            continue;
        }
        const uint16_t bits = glyph->rows[source_y];
        for (int source_x = 0; source_x < 16; ++source_x) {
            if ((bits & (1U << (15 - source_x))) == 0) {
                continue;
            }
            for (int dx = 0; dx < scale; ++dx) {
                const int pixel_x = x + source_x * scale + dx;
                if (pixel_x >= 0 && pixel_x < BSP_LCD_H_RES) {
                    row[pixel_x] = color;
                }
            }
        }
    }
}

static size_t utf8_decode(const char *text, uint32_t *codepoint)
{
    const uint8_t first = (uint8_t)text[0];
    if (first < 0x80) {
        *codepoint = first;
        return 1;
    }
    if ((first & 0xE0) == 0xC0 && (uint8_t)text[1] != 0) {
        *codepoint = ((uint32_t)(first & 0x1F) << 6) | ((uint8_t)text[1] & 0x3F);
        return 2;
    }
    if ((first & 0xF0) == 0xE0 && (uint8_t)text[1] != 0 && (uint8_t)text[2] != 0) {
        *codepoint = ((uint32_t)(first & 0x0F) << 12) |
                     (((uint8_t)text[1] & 0x3F) << 6) | ((uint8_t)text[2] & 0x3F);
        return 3;
    }
    if ((first & 0xF8) == 0xF0 && (uint8_t)text[1] != 0 &&
        (uint8_t)text[2] != 0 && (uint8_t)text[3] != 0) {
        *codepoint = ((uint32_t)(first & 0x07) << 18) |
                     (((uint8_t)text[1] & 0x3F) << 12) |
                     (((uint8_t)text[2] & 0x3F) << 6) | ((uint8_t)text[3] & 0x3F);
        return 4;
    }
    *codepoint = '?';
    return 1;
}

static int project_text_width(const char *project, int scale)
{
    int width = 0;
    for (size_t offset = 0; project[offset] != '\0';) {
        uint32_t codepoint = 0;
        const size_t consumed = utf8_decode(project + offset, &codepoint);
        offset += consumed;
        width += find_cjk_glyph(codepoint) == NULL ? (6 * scale) : (17 * scale);
    }
    return width;
}

static void paint_project_row(uint16_t *row, const char *project, int screen_y, int top_y, uint16_t color)
{
    const int scale = 2;
    int x = (BSP_LCD_H_RES - project_text_width(project, scale)) / 2;
    if (x < 2) {
        x = 2;
    }
    for (size_t offset = 0; project[offset] != '\0';) {
        uint32_t codepoint = 0;
        const size_t consumed = utf8_decode(project + offset, &codepoint);
        offset += consumed;
        const cjk_glyph_t *glyph = find_cjk_glyph(codepoint);
        if (glyph != NULL) {
            paint_cjk_row(row, x, screen_y, top_y, glyph, scale, color);
            x += 17 * scale;
        } else {
            paint_ascii_row(row, x, screen_y, top_y + 2, (char)(codepoint < 0x80 ? codepoint : '?'), scale, color);
            x += 6 * scale;
        }
    }
}

static void render_screen(const char *project, uint16_t background)
{
    if (s_panel == NULL) {
        return;
    }

    uint16_t *row = heap_caps_malloc(BSP_LCD_H_RES * sizeof(uint16_t), MALLOC_CAP_DMA);
    if (row == NULL) {
        return;
    }

    const int title_y = 20;
    const int complete_y = 60;
    const int project_y = 150;
    const cjk_glyph_t *complete_glyphs[2] = {
        find_cjk_glyph(0x5B8C),
        find_cjk_glyph(0x6210),
    };

    for (int y = 0; y < BSP_LCD_V_RES; ++y) {
        fill_row(row, background);
        for (int character = 0; character < 5; ++character) {
            paint_ascii_row(row, 95 + character * 24, y, title_y, "CODEX"[character], 3, TEXT_COLOR);
        }
        paint_cjk_row(row, 72, y, complete_y, complete_glyphs[0], 4, TEXT_COLOR);
        paint_cjk_row(row, 176, y, complete_y, complete_glyphs[1], 4, TEXT_COLOR);
        paint_project_row(row, project, y, project_y, TEXT_COLOR);
        (void)esp_lcd_panel_draw_bitmap(s_panel, 0, y, BSP_LCD_H_RES, y + 1, row);
    }
    free(row);
}

static bool append_utf8(char *output, size_t capacity, size_t *length, uint32_t codepoint)
{
    char encoded[4];
    size_t encoded_length = 0;
    if (codepoint <= 0x7F) {
        encoded[0] = (char)codepoint;
        encoded_length = 1;
    } else if (codepoint <= 0x7FF) {
        encoded[0] = (char)(0xC0 | (codepoint >> 6));
        encoded[1] = (char)(0x80 | (codepoint & 0x3F));
        encoded_length = 2;
    } else if (codepoint <= 0xFFFF) {
        encoded[0] = (char)(0xE0 | (codepoint >> 12));
        encoded[1] = (char)(0x80 | ((codepoint >> 6) & 0x3F));
        encoded[2] = (char)(0x80 | (codepoint & 0x3F));
        encoded_length = 3;
    } else {
        return false;
    }
    if (*length + encoded_length >= capacity) {
        return false;
    }
    memcpy(output + *length, encoded, encoded_length);
    *length += encoded_length;
    output[*length] = '\0';
    return true;
}

static int hex_value(char character)
{
    if (character >= '0' && character <= '9') {
        return character - '0';
    }
    if (character >= 'a' && character <= 'f') {
        return character - 'a' + 10;
    }
    if (character >= 'A' && character <= 'F') {
        return character - 'A' + 10;
    }
    return -1;
}

static bool json_string_value(const char *json, const char *key, char *output, size_t capacity)
{
    /* This is a bounded extractor for the fixed host protocol, not a general
       JSON parser. It intentionally accepts only string fields we own. */
    char needle[48];
    snprintf(needle, sizeof(needle), "\"%s\"", key);
    const char *cursor = strstr(json, needle);
    if (cursor == NULL) {
        return false;
    }
    cursor = strchr(cursor + strlen(needle), ':');
    if (cursor == NULL) {
        return false;
    }
    cursor++;
    while (*cursor == ' ' || *cursor == '\t') {
        cursor++;
    }
    if (*cursor != '"') {
        return false;
    }
    cursor++;
    size_t length = 0;
    output[0] = '\0';
    while (*cursor != '\0' && *cursor != '"') {
        if (*cursor != '\\') {
            if (length + 1 >= capacity) {
                break;
            }
            output[length++] = *cursor++;
            output[length] = '\0';
            continue;
        }
        cursor++;
        if (*cursor == 'u') {
            const int h0 = hex_value(cursor[1]);
            const int h1 = hex_value(cursor[2]);
            const int h2 = hex_value(cursor[3]);
            const int h3 = hex_value(cursor[4]);
            if (h0 < 0 || h1 < 0 || h2 < 0 || h3 < 0) {
                return false;
            }
            const uint32_t codepoint = (uint32_t)((h0 << 12) | (h1 << 8) | (h2 << 4) | h3);
            if (!append_utf8(output, capacity, &length, codepoint)) {
                break;
            }
            cursor += 5;
            continue;
        }
        const char escaped = *cursor++;
        switch (escaped) {
        case '"':
        case '\\':
        case '/':
            if (length + 1 < capacity) {
                output[length++] = escaped;
            }
            break;
        case 'b': if (length + 1 < capacity) output[length++] = '\b'; break;
        case 'f': if (length + 1 < capacity) output[length++] = '\f'; break;
        case 'n': if (length + 1 < capacity) output[length++] = '\n'; break;
        case 'r': if (length + 1 < capacity) output[length++] = '\r'; break;
        case 't': if (length + 1 < capacity) output[length++] = '\t'; break;
        default: break;
        }
        output[length] = '\0';
    }
    return true;
}

static void handle_message(const char *line)
{
    char type[32];
    char status[32];
    char project[PROJECT_CAPACITY];
    if (!json_string_value(line, "type", type, sizeof(type)) ||
        !json_string_value(line, "status", status, sizeof(status)) ||
        strcmp(type, "completion") != 0 || strcmp(status, "completed") != 0) {
        return;
    }
    if (!json_string_value(line, "project", project, sizeof(project)) || project[0] == '\0') {
        strncpy(project, "Codex", sizeof(project) - 1);
        project[sizeof(project) - 1] = '\0';
    }
    render_screen(project, COMPLETE_BACKGROUND);
}

static void serial_task(void *argument)
{
    (void)argument;
    /* USB Serial/JTAG messages are newline-delimited. A bounded buffer keeps a
       malformed host message from consuming heap used by the display DMA. */
    char line[RX_LINE_CAPACITY];
    size_t length = 0;
    uint8_t buffer[64];
    while (true) {
        const int received = usb_serial_jtag_read_bytes(buffer, sizeof(buffer), pdMS_TO_TICKS(100));
        if (received <= 0) {
            continue;
        }
        for (int index = 0; index < received; ++index) {
            const char character = (char)buffer[index];
            if (character == '\n') {
                line[length] = '\0';
                if (length > 0) {
                    handle_message(line);
                }
                length = 0;
            } else if (character != '\r') {
                if (length + 1 < sizeof(line)) {
                    line[length++] = character;
                } else {
                    length = 0;
                }
            }
        }
    }
}

void app_main(void)
{
    const bsp_display_config_t display_config = {
        .max_transfer_sz = BSP_LCD_H_RES * 40 * sizeof(uint16_t),
    };
    const esp_err_t display_result = bsp_display_new(&display_config, &s_panel, &s_panel_io);
    if (display_result == ESP_OK) {
        ESP_ERROR_CHECK(esp_lcd_panel_disp_on_off(s_panel, true));
        (void)bsp_display_backlight_on();
        render_screen("Codex", READY_BACKGROUND);
    } else {
        ESP_LOGE(TAG, "display initialization failed: %s", esp_err_to_name(display_result));
    }

    if (!usb_serial_jtag_is_driver_installed()) {
        usb_serial_jtag_driver_config_t usb_config = USB_SERIAL_JTAG_DRIVER_CONFIG_DEFAULT();
        usb_config.rx_buffer_size = RX_LINE_CAPACITY;
        usb_config.tx_buffer_size = 256;
        ESP_ERROR_CHECK(usb_serial_jtag_driver_install(&usb_config));
    }
    xTaskCreate(serial_task, "codex_serial", 4096, NULL, 5, NULL);
    ESP_LOGI(TAG, "ready");
}
