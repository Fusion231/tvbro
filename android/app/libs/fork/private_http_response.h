#pragma once

#include <cstdint>
#include <cstring>
#include <string>

// A private, bounded FFmpeg response boundary. Raw messages never leave JNI.
namespace tvbro_http {
static const char *const kPrefix = "tvbro/http-response";

inline char lower(char c) { return c >= 'A' && c <= 'Z' ? c + ('a' - 'A') : c; }
inline bool equal(const std::string &a, const char *b) {
    if (a.size() != std::strlen(b)) return false;
    for (size_t i = 0; i < a.size(); ++i) if (lower(a[i]) != lower(b[i])) return false;
    return true;
}
inline std::string trim(const std::string &value) {
    const size_t first = value.find_first_not_of(" \t\r\n");
    return first == std::string::npos ? std::string() : value.substr(first, value.find_last_not_of(" \t\r\n") - first + 1);
}
inline int decimal(const std::string &s) {
    if (s.empty()) return -1;
    int value = 0;
    for (char c : s) { if (c < '0' || c > '9' || value > 10000) return -1; value = value * 10 + c - '0'; }
    return value;
}
inline bool validRetry(const std::string &value) {
    if (value.empty() || value.size() > 64) return false;
    bool digits = true;
    uint64_t number = 0;
    for (char c : value) {
        if (c < '0' || c > '9') { digits = false; break; }
        const unsigned digit = c - '0';
        if (number > (UINT64_C(9223372036854775807) - digit) / 10) return false;
        number = number * 10 + digit;
    }
    if (digits) return true;
    // IMF-fixdate only. The receiver also validates this before using policy.
    if (value.size() != 29 || value.substr(3, 2) != ", " || value[7] != ' ' || value[11] != ' ' ||
        value[16] != ' ' || value[19] != ':' || value[22] != ':' || value.substr(25) != " GMT") return false;
    const char *days[] = {"Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"};
    const char *months[] = {"Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"};
    int weekday = -1, month = -1;
    for (int i = 0; i < 7; ++i) if (value.substr(0, 3) == days[i]) weekday = i;
    for (int i = 0; i < 12; ++i) if (value.substr(8, 3) == months[i]) month = i + 1;
    const int day = decimal(value.substr(5, 2)), year = decimal(value.substr(12, 4));
    const int hour = decimal(value.substr(17, 2)), minute = decimal(value.substr(20, 2)), second = decimal(value.substr(23, 2));
    if (weekday < 0 || month < 1 || day < 1 || year < 1601 || hour < 0 || hour > 23 || minute < 0 || minute > 59 || second < 0 || second > 59) return false;
    const int lengths[] = {31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31};
    const bool leap = year % 4 == 0 && (year % 100 != 0 || year % 400 == 0);
    if (day > lengths[month - 1] + (month == 2 && leap ? 1 : 0)) return false;
    const int offsets[] = {0, 3, 2, 5, 0, 3, 5, 1, 4, 6, 2, 4};
    const int y = year - (month < 3 ? 1 : 0);
    return (y + y / 4 - y / 100 + y / 400 + offsets[month - 1] + day) % 7 == weekday;
}
inline std::string origin(const std::string &url) {
    const size_t schemeEnd = url.find("://");
    if (schemeEnd == std::string::npos || schemeEnd > 5 || url.size() > 8192) return {};
    std::string scheme = url.substr(0, schemeEnd);
    for (char &c : scheme) c = lower(c);
    if (scheme != "http" && scheme != "https") return {};
    const size_t start = schemeEnd + 3, end = url.find_first_of("/?#", start);
    std::string authority = url.substr(start, end == std::string::npos ? end : end - start);
    const size_t at = authority.rfind('@');
    if (at != std::string::npos) authority.erase(0, at + 1);
    if (authority.empty() || authority.size() > 320) return {};
    std::string host, port;
    if (authority[0] == '[') {
        const size_t close = authority.find(']');
        if (close == std::string::npos || close == 1) return {};
        host = authority.substr(0, close + 1);
        if (close + 1 < authority.size()) { if (authority[close + 1] != ':') return {}; port = authority.substr(close + 2); }
        for (size_t i = 1; i < close; ++i) { char c = lower(host[i]); if (!((c >= 'a' && c <= 'f') || (c >= '0' && c <= '9') || c == ':' || c == '.')) return {}; }
    } else {
        const size_t colon = authority.find(':');
        host = authority.substr(0, colon);
        if (colon != std::string::npos) port = authority.substr(colon + 1);
        if (host.empty() || host.size() > 253) return {};
        for (char c : host) if (!((lower(c) >= 'a' && lower(c) <= 'z') || (c >= '0' && c <= '9') || c == '-' || c == '.')) return {};
    }
    if (authority.back() == ':' || (!port.empty() && (decimal(port) < 1 || decimal(port) > 65535))) return {};
    for (char &c : host) c = lower(c);
    return scheme + "://" + host + (port.empty() ? "" : ":" + port) + "/";
}

struct Response {
    int status = 0;
    std::string retry, responseOrigin;
    std::string payload() const {
        return "status=" + std::to_string(status) + (retry.empty() ? "" : ";retry-after=" + retry) +
            (responseOrigin.empty() ? "" : ";response-origin=" + responseOrigin);
    }
};

class Parser {
    bool active_ = false, waiting_ = false, retrySeen_ = false, badRetry_ = false;
    int status_ = 0, headers_ = 0;
    std::string retry_, origin_, redirect_;
    void clearBlock() { status_ = 0; headers_ = 0; retrySeen_ = badRetry_ = false; retry_.clear(); redirect_.clear(); }
    bool emit(Response &out) {
        const bool refusal = status_ == 401 || status_ == 403 || status_ == 429 || (status_ == 503 && !retry_.empty() && !badRetry_);
        if (refusal) { out.status = status_; out.retry = badRetry_ ? "" : retry_; out.responseOrigin = origin_; }
        if (status_ >= 300 && status_ < 400 && !redirect_.empty()) origin_ = redirect_;
        clearBlock(); return refusal;
    }
public:
    void start(const char *url) { clearBlock(); active_ = true; waiting_ = true; origin_ = origin(url ? url : ""); }
    void started() { if (active_) waiting_ = false; }
    void stop() { active_ = waiting_ = false; clearBlock(); origin_.clear(); }
    bool end(Response &out) { if (!active_ || waiting_) return false; const bool result = emit(out); stop(); return result; }
    bool feed(const char *prefix, const char *text, Response &out) {
        if (!active_ || waiting_ || !prefix || std::strcmp(prefix, "ffmpeg") || !text) return false;
        size_t length = 0; while (length <= 8192 && text[length]) ++length;
        if (length > 8192) { badRetry_ = true; return false; }
        std::string line(text, length);
        if (line.compare(0, 6, "http: ") == 0) line.erase(0, 6);
        else if (line.compare(0, 7, "https: ") == 0) line.erase(0, 7);
        else return false;
        if (line.compare(0, 11, "HTTP error ") == 0 && !status_) {
            const int code = decimal(line.substr(11, 3));
            if (code >= 400 && code <= 599) status_ = code;
            return false;
        }
        if (line.compare(0, 8, "header='") != 0) return false;
        line = trim(line.substr(8));
        if (line.empty() || line.back() != '\'') { badRetry_ = true; return false; }
        line.pop_back();
        if (line.find_first_of("\r\n") != std::string::npos) { badRetry_ = true; return false; }
        if (line.compare(0, 5, "HTTP/") == 0) {
            clearBlock();
            const size_t space = line.find(' ');
            const std::string version = line.substr(0, space);
            if (version != "HTTP/1.0" && version != "HTTP/1.1" && version != "HTTP/2" && version != "HTTP/2.0" && version != "HTTP/3" && version != "HTTP/3.0") return false;
            if (space != std::string::npos && line.size() >= space + 4) {
                const int code = decimal(line.substr(space + 1, 3));
                if (code >= 100 && code <= 599 && (line.size() == space + 4 || line[space + 4] == ' ')) status_ = code;
            }
            return false;
        }
        if (!status_) return false;
        if (line.empty()) return emit(out);
        if (++headers_ > 128) { badRetry_ = true; return false; }
        const size_t colon = line.find(':');
        if (colon == std::string::npos) return false;
        const std::string key = trim(line.substr(0, colon));
        if (equal(key, "Retry-After")) {
            const std::string value = trim(line.substr(colon + 1));
            if (retrySeen_ || !validRetry(value)) badRetry_ = true;
            else retry_ = value;
            retrySeen_ = true;
        } else if (equal(key, "Location") && status_ >= 300 && status_ < 400) {
            std::string value = trim(line.substr(colon + 1));
            if (value.compare(0, 2, "//") == 0 && !origin_.empty()) value = origin_.substr(0, origin_.find(':') + 1) + value;
            redirect_ = origin(value);
        }
        return false;
    }
};
} // namespace tvbro_http
