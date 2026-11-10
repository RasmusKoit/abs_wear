import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

/// How a server lets users log in, from its `/status`: with a password,
/// with SSO, or both.
class ServerLogin {
  const ServerLogin({
    required this.password,
    required this.sso,
    this.ssoButtonText,
    this.ssoAutoLaunch = false,
  });

  final bool password;
  final bool sso;

  /// The admin's label for the SSO button, if they set one.
  final String? ssoButtonText;

  /// The admin wants SSO to start without asking (when both are offered).
  final bool ssoAutoLaunch;

  /// Reads [serverUrl]'s `/status`. Throws [ServerStatusException] on an
  /// error response, and the network's own errors.
  static Future<ServerLogin> fetch(String serverUrl) async {
    final response = await http
        .get(Uri.parse('$serverUrl/status'))
        .timeout(const Duration(seconds: 20));
    if (response.statusCode != 200) {
      throw ServerStatusException(response.statusCode);
    }
    final status = jsonDecode(response.body) as Map<String, dynamic>;
    final methods = (status['authMethods'] as List?)?.cast<String>() ?? [];
    final form = status['authFormData'] as Map<String, dynamic>? ?? const {};
    final buttonText = (form['authOpenIDButtonText'] as String?)?.trim();
    return ServerLogin(
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

class ServerStatusException implements Exception {
  const ServerStatusException(this.statusCode);

  final int statusCode;

  @override
  String toString() => 'ServerStatusException($statusCode)';
}
