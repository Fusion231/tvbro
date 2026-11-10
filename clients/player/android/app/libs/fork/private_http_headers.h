#pragma once
#include <string>
#include <vector>

namespace tvbro_http {
static const char *const kHeadersProperty = "tvbro/http-request-headers";
inline int hexDigit(char c) {
    if (c >= '0' && c <= '9') return c - '0';
    if (c >= 'a' && c <= 'f') return c - 'a' + 10;
    if (c >= 'A' && c <= 'F') return c - 'A' + 10;
    return -1;
}
inline bool utf8(const std::string &text) {
    for (size_t i = 0; i < text.size();) {
        const unsigned char c = text[i++];
        if (c < 0x80) continue;
        const size_t count = c >= 0xc2 && c <= 0xdf ? 1 : c >= 0xe0 && c <= 0xef ? 2 : c >= 0xf0 && c <= 0xf4 ? 3 : 0;
        if (!count || i + count > text.size()) return false;
        const unsigned char first = text[i];
        if ((c == 0xe0 && first < 0xa0) || (c == 0xed && first >= 0xa0) || (c == 0xf0 && first < 0x90) || (c == 0xf4 && first >= 0x90)) return false;
        for (size_t n = 0; n < count; ++n) { const unsigned char next = text[i++]; if (next < 0x80 || next > 0xbf) return false; }
    }
    return true;
}
inline bool headerField(const std::string &field) {
    const size_t colon = field.find(':');
    if (!colon || colon == std::string::npos || !utf8(field)) return false;
    for (size_t i = 0; i < colon; ++i) {
        const unsigned char c = field[i];
        if (!((c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9') || std::string("!#$%&'*+-.^_`|~").find(c) != std::string::npos)) return false;
    }
    for (size_t i = colon + 1; i < field.size(); ++i) {
        const unsigned char c = field[i];
        if ((c < 0x20 && c != '\t') || c == 0x7f) return false;
    }
    return true;
}
inline bool wireNumber(const std::string &wire, size_t &at, char separator, size_t maximum, size_t &out) {
    const size_t start = at; size_t value = 0;
    while (at < wire.size() && wire[at] >= '0' && wire[at] <= '9') {
        const unsigned digit = wire[at++] - '0';
        if (value > (maximum - digit) / 10 || digit > maximum) return false;
        value = value * 10 + digit;
    }
    if (at == start || at >= wire.size() || wire[at++] != separator || value > maximum) return false;
    out = value; return true;
}
inline bool parseHeaders(const char *input, std::vector<std::string> &out) {
    if (!input) return false;
    size_t length = 0; while (length <= 65536 && input[length]) ++length;
    if (length > 65536) return false;
    const std::string wire(input, length);
    if (wire.compare(0, 3, "v1;") != 0) return false;
    size_t at = 3, count = 0;
    if (!wireNumber(wire, at, ';', 128, count)) return false;
    std::vector<std::string> parsed; parsed.reserve(count);
    for (size_t i = 0; i < count; ++i) {
        size_t bytes = 0;
        if (!wireNumber(wire, at, ':', 8192, bytes) || bytes * 2 > wire.size() - at) return false;
        std::string field; field.reserve(bytes);
        for (size_t n = 0; n < bytes; ++n) {
            const int high = hexDigit(wire[at++]), low = hexDigit(wire[at++]);
            if (high < 0 || low < 0) return false;
            field.push_back(static_cast<char>((high << 4) | low));
        }
        if (!headerField(field)) return false;
        parsed.push_back(field);
    }
    if (at != wire.size()) return false;
    out.swap(parsed); return true;
}
} // namespace tvbro_http
