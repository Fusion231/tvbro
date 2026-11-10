import 'dart:io';

/// Only response status and validated retry timing leave the private mpv log
/// client. URLs, request headers, cookies and response bodies are discarded.
class MpvHttpRefusal {
  const MpvHttpRefusal(this.status, this.retryAfter);
  final int status;
  final String? retryAfter;
}

class MpvHttpResponseParser {
  int? _status;
  String? _retryAfter;

  void reset() {
    _status = null;
    _retryAfter = null;
  }

  MpvHttpRefusal? addCurlResponseLine(String line) {
    if (!line.startsWith('<')) return null;
    final status = RegExp(r'^< HTTP/\S+\s+(\d{3})(?:\s|$)').firstMatch(line);
    if (status != null) {
      reset();
      _status = int.parse(status[1]!);
      return null;
    }
    if (line.trimRight() == '<') {
      final result =
          const [401, 403, 429].contains(_status) ||
              (_status == 503 && _retryAfter != null)
          ? MpvHttpRefusal(_status!, _retryAfter)
          : null;
      reset();
      return result;
    }
    if (_status == null) return null;
    final retry = RegExp(
      r'^< retry-after:\s*(.*?)\s*$',
      caseSensitive: false,
    ).firstMatch(line)?[1];
    if (retry == null || retry.length > 128) return null;
    final seconds = int.tryParse(retry);
    if (seconds != null) {
      if (seconds >= 0) _retryAfter = retry;
    } else {
      try {
        HttpDate.parse(retry);
        _retryAfter = retry;
      } on FormatException {
        // An invalid header must not become a deadline.
      } on HttpException {
        // Preserve no arbitrary header text, including diagnostics.
      }
    }
    return null;
  }
}
