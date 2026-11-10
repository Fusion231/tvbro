#include "private_http_response.h"
#include "private_http_headers.h"
#include <cassert>
#include <iostream>

using tvbro_http::Parser;
using tvbro_http::Response;
static bool header(Parser &parser, const std::string &value, Response &response) {
    const std::string message = "http: header='" + value + "'\n";
    return parser.feed("ffmpeg", message.c_str(), response);
}
int main() {
    int checks = 0;
    const auto check = [&](bool ok) { ++checks; assert(ok); };
    check(tvbro_http::validRetry("0")); check(tvbro_http::validRetry("120"));
    check(tvbro_http::validRetry("9223372036854775807"));
    for (const auto &value : {"", "-1", "+12", "1.5", "9223372036854775808", "120\r\nAuthorization: secret", "Mon, 31 Feb 2026 12:00:00 GMT", "Sun, 26 Oct 2026 12:00:00 GMT"}) check(!tvbro_http::validRetry(value));
    check(tvbro_http::validRetry("Mon, 26 Oct 2026 12:00:00 GMT"));
    check(tvbro_http::origin("http://user:secret@EXAMPLE.test:8080/private/token?q=secret#x") == "http://example.test:8080/");
    check(tvbro_http::origin("https://[::1]:443/path") == "https://[::1]:443/");
    for (const auto &value : {"file:///private", "http://bad host/path", "http://host:0/", "http://host:65536/", "http://host:443evil/", "http://host;secret/path"}) check(tvbro_http::origin(value).empty());
    Parser parser; Response response;
    parser.start("http://user:secret@provider.test:1234/private?q=secret");
    check(!header(parser, "HTTP/1.1 429 Too Many Requests", response));
    parser.started();
    check(!header(parser, "HTTP/1.1 429 Too Many Requests", response));
    check(!header(parser, "Set-Cookie: canary-secret", response));
    check(!header(parser, "Retry-After: 120", response));
    check(header(parser, "", response));
    check(response.payload() == "status=429;retry-after=120;response-origin=http://provider.test:1234/");
    check(response.payload().find("secret") == std::string::npos);
    check(!header(parser, "", response));
    header(parser, "HTTP/1.1 403 Forbidden", response);
    header(parser, "Retry-After: 5", response);header(parser, "Retry-After: 6", response);
    check(header(parser, "", response));check(response.retry.empty());
    header(parser, "HTTP/1.1 503 Unavailable", response);check(!header(parser, "", response));
    header(parser, "HTTP/1.1 503 Unavailable", response);
    header(parser, "Retry-After: Mon, 26 Oct 2026 12:00:00 GMT", response);
    check(header(parser, "", response));check(response.retry == "Mon, 26 Oct 2026 12:00:00 GMT");
    header(parser, "HTTP/1.1 302 Redirect", response);
    header(parser, "Location: https://user:secret@CDN.test:8443/private?token=canary", response);
    check(!header(parser, "", response));
    header(parser, "HTTP/1.1 429 Limit", response);header(parser, "Retry-After: 30", response);
    check(header(parser, "", response));check(response.responseOrigin == "https://cdn.test:8443/");
    header(parser, "HTTP/1.1 403 Forbidden", response);header(parser, "Retry-After: 4", response);
    parser.start("https://next.test/path");check(!parser.end(response));parser.started();
    header(parser, "HTTP/1.1 200 OK", response);check(!header(parser, "", response));
    size_t healthyCallbacks = 0;
    for (int i = 0; i < 100000; ++i) {
        healthyCallbacks += parser.feed("ffmpeg/video", "decoder frame: canary-secret", response);
        healthyCallbacks += parser.feed("ffmpeg", "http: Statistics: private request data", response);
        healthyCallbacks += header(parser, "HTTP/1.1 200 OK", response);
        healthyCallbacks += header(parser, "Set-Cookie: canary-secret", response);
        healthyCallbacks += header(parser, "", response);
    }
    check(healthyCallbacks == 0);
    header(parser, "HTTP/1.1 429 Limit", response);
    header(parser, "Retry-After: 120", response);
    check(!parser.feed("ffmpeg", std::string(9000, 'x').c_str(), response));
    check(header(parser, "", response));check(response.retry.empty());
    header(parser, "HTTP/1.1 403 Forbidden", response);parser.stop();check(!parser.end(response));
    check(!header(parser, "HTTP/1.1 429 Limit", response));
    parser.start("https://fallback.test/private");parser.started();
    check(!parser.feed("ffmpeg", "http: HTTP error 403 Forbidden\n", response));
    check(parser.end(response));check(response.status == 403 && response.retry.empty());
    const auto wire = [](const std::vector<std::string> &fields) {
        std::string result = "v1;" + std::to_string(fields.size()) + ";";
        const char *hex = "0123456789abcdef";
        for (const auto &field : fields) {
            result += std::to_string(field.size()) + ":";
            for (unsigned char c : field) { result += hex[c >> 4]; result += hex[c & 15]; }
        }
        return result;
    };
    std::vector<std::string> headers;
    const std::vector<std::string> literal = {"Authorization: Bearer canary", "Cookie: a=1; b=2", "X-Comma: one,two", "X-Path: C:\\media\\a,b", "X-Unicode: Za\xc5\xbc\xc3\xb3\xc5\x82\xc4\x87\xf0\x9f\x98\x80"};
    check(tvbro_http::parseHeaders(wire(literal).c_str(), headers));check(headers == literal);
    check(tvbro_http::parseHeaders("v1;0;", headers));check(headers.empty());
    for (const auto &invalid : {"v2;0;", "v1;129;", "v1;1;8193:", "v1;1;2:zzzz", "v1;1;9999999999999999999999999:", "v1;0;trailing"}) check(!tvbro_http::parseHeaders(invalid, headers));
    for (const auto &field : {std::string("X: one\r\nAuthorization: injected"), std::string("X: \0injected", 12), std::string("Bad Name: value"), std::string(": value"), std::string("X: \xc0\x80"), std::string("X: \xed\xa0\x80")}) {
        headers = {"Previous: preserved"};
        check(!tvbro_http::parseHeaders(wire({"Good: first", field}).c_str(), headers));
        check(headers.size() == 1 && headers[0] == "Previous: preserved");
    }
    check(!tvbro_http::parseHeaders(std::string(65537, 'a').c_str(), headers));
    std::cout << "{\"status\":\"passed\",\"checks\":" << checks << ",\"healthyMessages\":500000,\"healthyMetadataCallbacks\":" << healthyCallbacks << "}\n";
}
