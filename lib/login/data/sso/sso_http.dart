import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

/// The minimal "browser" SSO login needs: one HTTP client, redirects handled
/// by the caller, and cookies kept per server. Cookies are kept for the few
/// minutes a login takes, so path, expiry and domain rules are ignored: each
/// one goes back only to the host and port that set it.
class SsoHttp {
  SsoHttp([http.Client? client]) : _client = client ?? http.Client();

  final http.Client _client;
  final _cookies = <String, Map<String, String>>{};

  static const timeout = Duration(seconds: 20);

  /// Sends one request without following redirects. JSON [body] is encoded
  /// and sent with a JSON content type; [form] fields (in order, names may
  /// repeat) are sent form-encoded, like a browser posting an HTML form.
  /// [wait] replaces [timeout] for requests the server holds open (long
  /// polling). It covers the whole response, and a request that runs out of
  /// time is aborted (so the server stops working on it) before
  /// [TimeoutException] is thrown.
  Future<http.Response> send(
    String method,
    Uri url, {
    Object? body,
    List<(String, String)>? form,
    Map<String, String> headers = const {},
    Duration wait = timeout,
  }) async {
    final abort = Completer<void>();
    final request =
        http.AbortableRequest(method, url, abortTrigger: abort.future)
          ..followRedirects = false
          ..headers.addAll({'Accept': 'application/json', ...headers});
    final cookies = _cookies[_origin(url)];
    if (cookies != null && cookies.isNotEmpty) {
      request.headers['Cookie'] = [
        for (final MapEntry(:key, :value) in cookies.entries) '$key=$value',
      ].join('; ');
    }
    if (body != null) {
      request
        ..headers['Content-Type'] = 'application/json'
        ..body = jsonEncode(body);
    } else if (form != null) {
      request
        ..headers['Content-Type'] = 'application/x-www-form-urlencoded'
        ..body = form.map((f) => '${_encode(f.$1)}=${_encode(f.$2)}').join('&');
    }
    Future<http.Response> exchange() async =>
        await http.Response.fromStream(await _client.send(request));
    final http.Response response;
    try {
      response = await exchange().timeout(wait);
    } on TimeoutException {
      abort.complete();
      rethrow;
    }
    _store(url, response);
    return response;
  }

  /// The value of cookie [name] set by [url]'s server, if any.
  String? cookie(Uri url, String name) => _cookies[_origin(url)]?[name];

  /// Where a redirect [response] to [from] points, made absolute. Null when
  /// it isn't a redirect.
  static Uri? redirectTarget(Uri from, http.Response response) {
    if (!const {301, 302, 303, 307, 308}.contains(response.statusCode)) {
      return null;
    }
    final location = response.headers['location'];
    if (location == null || location.isEmpty) return null;
    return from.resolve(location);
  }

  void close() => _client.close();

  void _store(Uri url, http.Response response) {
    final setCookies = response.headersSplitValues['set-cookie'];
    if (setCookies == null) return;
    final jar = _cookies.putIfAbsent(_origin(url), () => {});
    for (final header in setCookies) {
      final parts = header.split(';');
      final pair = parts.first;
      final eq = pair.indexOf('=');
      if (eq <= 0) continue;
      final name = pair.substring(0, eq).trim();
      final value = pair.substring(eq + 1).trim();
      final deleted =
          value.isEmpty ||
          parts.skip(1).any((a) {
            final attr = a.trim().toLowerCase();
            return attr == 'max-age=0' || attr.startsWith('max-age=-');
          });
      if (deleted) {
        jar.remove(name);
      } else {
        jar[name] = value;
      }
    }
  }

  static String _encode(String s) => Uri.encodeQueryComponent(s);

  static String _origin(Uri url) => '${url.scheme}://${url.host}:${url.port}';
}
