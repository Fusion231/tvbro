import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

class MetadataReply {
  const MetadataReply(this.body, {this.status = 200});
  final Object body;
  final int status;
}

class MetadataHttp extends Fake implements HttpClient {
  MetadataHttp(this.respond);
  final MetadataReply Function(Uri uri) respond;
  final urls = <Uri>[];
  final headers = <MetadataHeaders>[];
  final times = <DateTime>[];
  final loginBodies = <String>[];

  @override
  Future<HttpClientRequest> getUrl(Uri url) async {
    urls.add(url);
    times.add(DateTime.now());
    final header = MetadataHeaders();
    headers.add(header);
    return _Request(respond(url), header);
  }

  @override
  Future<HttpClientRequest> postUrl(Uri url) async => _Request(
    const MetadataReply({
      'data': {'token': 'fixture-token'},
    }),
    MetadataHeaders(),
    onWrite: (body) => loginBodies.add('$body'),
  );

  @override
  void close({bool force = false}) {}
}

class _Request extends Fake implements HttpClientRequest {
  _Request(this.reply, this.headers, {this.onWrite});
  final MetadataReply reply;
  final void Function(Object?)? onWrite;
  @override
  final HttpHeaders headers;
  @override
  void write(Object? object) => onWrite?.call(object);
  @override
  Future<HttpClientResponse> close() async => _Response(reply);
}

class _Response extends Fake implements HttpClientResponse {
  _Response(this.reply) : bytes = utf8.encode(jsonEncode(reply.body));
  final MetadataReply reply;
  final List<int> bytes;
  @override
  int get statusCode => reply.status;
  @override
  int get contentLength => bytes.length;
  @override
  HttpHeaders get headers => MetadataHeaders();
  @override
  StreamSubscription<List<int>> listen(
    void Function(List<int>)? onData, {
    Function? onError,
    void Function()? onDone,
    bool? cancelOnError,
  }) => Stream.value(bytes).listen(
    onData,
    onError: onError,
    onDone: onDone,
    cancelOnError: cancelOnError,
  );
}

class MetadataHeaders extends Fake implements HttpHeaders {
  final values = <String, String>{};
  @override
  void set(String name, Object value, {bool preserveHeaderCase = false}) =>
      values[name] = '$value';
  @override
  String? value(String name) => values[name];
  @override
  set contentType(ContentType? value) {}
}
