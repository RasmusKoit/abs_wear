import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

/// How a server lets users log in, from its `/status`: with a password,
/// with SSO, or both.
class ServerLogin {
  const ServerLogin({
    required this.serverUrl,
    required this.password,
    required this.sso,
    this.ssoButtonText,
    this.ssoAutoLaunch = false,
  });

  /// The server's address after any redirects (e.g. http to https), to
  /// use for the login itself: SSO follows no redirects of the server's.
  final String serverUrl;

  final bool password;
  final bool sso;

  /// The admin's label for the SSO button, if they set one.
  final String? ssoButtonText;

  /// The admin wants SSO to start without asking (when both are offered).
  final bool ssoAutoLaunch;

  /// Reads [serverUrl]'s `/status`. Throws [ServerStatusException] on an
  /// error response, and the network's own errors.
  static Future<ServerLogin> fetch(String serverUrl) async {
    var base = serverUrl;
    http.Response response;
    final client = http.Client();
    try {
      for (var hops = 0; ; hops++) {
        final status = Uri.parse('$base/status');
        final request = http.Request('GET', status)..followRedirects = false;
        response = await http.Response.fromStream(
          await client.send(request).timeout(_timeout),
        ).timeout(_timeout);
        final location = response.headers['location'];
        if (!_redirects.contains(response.statusCode) || location == null) {
          break;
        }
        // A server that moved (http to https, another host or path): carry
        // on at the new address, which must still be its /status.
        final next = status.resolve(location);
        if (hops >= 5 || !next.path.endsWith('/status')) {
          throw ServerStatusException(response.statusCode);
        }
        final path = next.path.substring(
          0,
          next.path.length - '/status'.length,
        );
        base = next.replace(path: path, query: '', fragment: '').toString();
        base = base.replaceAll(RegExp(r'[?#]+$'), '');
      }
    } finally {
      client.close();
    }
    if (response.statusCode != 200) {
      throw ServerStatusException(response.statusCode);
    }
    final status = jsonDecode(response.body) as Map<String, dynamic>;
    final methods = (status['authMethods'] as List?)?.cast<String>() ?? [];
    final form = status['authFormData'] as Map<String, dynamic>? ?? const {};
    final buttonText = (form['authOpenIDButtonText'] as String?)?.trim();
    return ServerLogin(
      serverUrl: base,
      // Servers from before SSO send no methods: passwords only.
      password: methods.isEmpty || methods.contains('local'),
      sso: methods.contains('openid'),
      ssoButtonText: buttonText == null || buttonText.isEmpty
          ? null
          : buttonText,
      ssoAutoLaunch: form['authOpenIDAutoLaunch'] == true,
    );
  }
}

const _timeout = Duration(seconds: 20);
const _redirects = {301, 302, 303, 307, 308};

class ServerStatusException implements Exception {
  const ServerStatusException(this.statusCode);

  final int statusCode;

  @override
  String toString() => 'ServerStatusException($statusCode)';
}
