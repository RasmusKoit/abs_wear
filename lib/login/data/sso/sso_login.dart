import 'dart:convert';
import 'dart:math';

import 'package:abs_wear/login/data/sso/authentik_adapter.dart';
import 'package:abs_wear/login/data/sso/sso_http.dart';
import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;

/// Redirect URI the server admin allows for ABS Wear under Settings →
/// Authentication → Allowed Mobile Redirect URIs. Nothing ever opens it:
/// the watch reads the code from the redirect itself.
const ssoRedirectUri = 'abswear://oauth';

/// What a field on an SSO login screen asks for.
enum SsoField { username, password, code }

/// The next thing the user has to do on the watch.
sealed class SsoStep {
  const SsoStep();
}

/// Fill in [fields] (in this order). [user] is the account being logged in,
/// once the identity provider knows it. [retry] means the last answer was
/// wrong (a wrong password or code).
class SsoPrompt extends SsoStep {
  const SsoPrompt(this.fields, {this.user, this.retry = false});

  final List<SsoField> fields;
  final String? user;
  final bool retry;
}

/// Allow [app] to use the account (the identity provider's consent screen).
class SsoConsent extends SsoStep {
  const SsoConsent(this.app);

  final String app;
}

/// Logged in: [data] is the server's login response, the same as for
/// password login (`user`, `userDefaultLibraryId`, ...).
class SsoDone extends SsoStep {
  const SsoDone(this.data);

  final Map<String, dynamic> data;
}

enum SsoError {
  /// The server has no SSO (or is older than ABS 2.7).
  notEnabled,

  /// The server doesn't allow [ssoRedirectUri] yet.
  redirectNotAllowed,

  /// The identity provider's login page isn't one the watch can drive.
  unsupportedProvider,

  /// The identity provider asks for something the watch can't do (passkey,
  /// captcha, a sign-up form).
  unsupportedStep,

  /// The identity provider refused this user for the app.
  accessDenied,

  /// SSO worked, but the user has no Audiobookshelf account.
  noAccount,

  /// Anything else: an unexpected answer, a login that went stale.
  failed,
}

class SsoException implements Exception {
  const SsoException(this.error, [this.detail]);

  final SsoError error;
  final String? detail;

  @override
  String toString() =>
      'SsoException($error${detail == null ? '' : ': $detail'})';
}

/// Drives one identity provider's login screens over plain HTTP.
abstract class IdpAdapter {
  /// The identity provider's product name, shown above its screens.
  String get name;

  /// The first screen, starting from the identity provider's [page].
  Future<SsoStep> begin(Uri page);

  /// Sends the user's [answer] to the current screen. Returns the next
  /// screen, or null once the identity provider redirects back to
  /// [redirect] (where the caller carries on).
  Future<SsoStep?> submit(Map<SsoField, String> answer);

  /// Where the identity provider sent the browser after the last screen.
  Uri? get redirect;
}

/// One SSO login on the watch, from the server's `/auth/openid` to its
/// callback, with the identity provider's screens shown natively in between.
///
/// Call [start], show each returned [SsoStep] and pass the answers to
/// [submit] until it returns [SsoDone]. [close] when finished or cancelled.
class SsoLogin {
  SsoLogin._(this.serverUrl, this._http);

  /// [serverUrl] without a trailing slash, as for password login.
  final String serverUrl;
  final SsoHttp _http;
  late final String _state = _random(24);
  late final String _verifier = _random(48);
  IdpAdapter? _idp;

  static const _maxRedirects = 30;

  /// Checks that the server offers SSO and walks to the identity provider's
  /// first screen. Throws [SsoException], or the network's own errors.
  static Future<(SsoLogin, SsoStep)> start(
    String serverUrl, {
    http.Client? client,
  }) async {
    final login = SsoLogin._(serverUrl, SsoHttp(client));
    try {
      await login._checkServer();
      final step = await login._begin();
      return (login, step);
    } on Object {
      login.close();
      rethrow;
    }
  }

  /// Answers the current screen. A [SsoConsent] takes an empty answer.
  Future<SsoStep> submit(Map<SsoField, String> answer) async {
    final idp = _idp;
    if (idp == null) throw const SsoException(SsoError.failed, 'not started');
    final next = await idp.submit(answer);
    if (next != null) return next;
    return await _finish(idp.redirect!);
  }

  /// The identity provider asking the questions (once known).
  String? get provider => _idp?.name;

  void close() => _http.close();

  Future<void> _checkServer() async {
    final response = await _http.send('GET', Uri.parse('$serverUrl/status'));
    if (response.statusCode != 200) {
      throw SsoException(SsoError.failed, 'status ${response.statusCode}');
    }
    final status = jsonDecode(response.body) as Map<String, dynamic>;
    final methods = (status['authMethods'] as List?)?.cast<String>() ?? [];
    if (!methods.contains('openid')) {
      throw const SsoException(SsoError.notEnabled);
    }
  }

  Future<SsoStep> _begin() async {
    final challenge = base64Url
        .encode(sha256.convert(utf8.encode(_verifier)).bytes)
        .replaceAll('=', '');
    final start = Uri.parse('$serverUrl/auth/openid').replace(
      queryParameters: {
        'response_type': 'code',
        'redirect_uri': ssoRedirectUri,
        'code_challenge': challenge,
        'code_challenge_method': 'S256',
        'state': _state,
        'client_id': 'abs-wear',
      },
    );
    final response = await _http.send('GET', start);
    final target = SsoHttp.redirectTarget(start, response);
    if (target == null) {
      final text = response.body;
      if (response.statusCode == 400 && text.contains('redirect_uri')) {
        throw const SsoException(SsoError.redirectNotAllowed);
      }
      if (response.statusCode == 400 || response.statusCode == 500) {
        // "OpenID Connect settings are not valid", or SSO turned off.
        throw SsoException(SsoError.notEnabled, text);
      }
      throw SsoException(SsoError.failed, 'start ${response.statusCode}');
    }
    // Into the identity provider, up to its first login page.
    final (page, back) = await _follow(target);
    if (back != null) {
      // Already signed in there: straight back to the server.
      return await _finish(back);
    }
    final idp = _adapterFor(page!);
    if (idp == null) {
      throw SsoException(SsoError.unsupportedProvider, page.toString());
    }
    _idp = idp;
    return await idp.begin(page);
  }

  /// Follows redirects from [url] until a page (returned first) or the
  /// redirect back to the watch (returned second).
  Future<(Uri?, Uri?)> _follow(Uri url) async {
    var current = url;
    for (var i = 0; i < _maxRedirects; i++) {
      if (_isRedirectUri(current)) return (null, current);
      final response = await _http.send(
        'GET',
        current,
        headers: const {'Accept': 'text/html,application/json'},
      );
      final next = SsoHttp.redirectTarget(current, response);
      if (next == null) {
        if (response.statusCode != 200) {
          throw SsoException(
            SsoError.failed,
            '${response.statusCode} at ${current.path}',
          );
        }
        return (current, null);
      }
      current = next;
    }
    throw const SsoException(SsoError.failed, 'too many redirects');
  }

  IdpAdapter? _adapterFor(Uri page) {
    if (AuthentikAdapter.matches(page)) {
      return AuthentikAdapter(_http, followRedirects: _follow);
    }
    return null;
  }

  /// From the identity provider's last redirect back to the server, to the
  /// redirect to [ssoRedirectUri], then the code exchange.
  Future<SsoStep> _finish(Uri from) async {
    final (page, back) = await _follow(from);
    if (back == null) {
      // A page instead of the redirect back, e.g. an error page.
      throw SsoException(SsoError.failed, 'stopped at ${page?.path}');
    }
    final query = back.queryParameters;
    final code = query['code'];
    if (query['state'] != _state) {
      throw const SsoException(SsoError.failed, 'state mismatch');
    }
    // The server forwards "undefined" when the identity provider sent an
    // error instead of a code.
    if (code == null || code.isEmpty || code == 'undefined') {
      throw const SsoException(SsoError.failed, 'no code');
    }
    final callback = Uri.parse('$serverUrl/auth/openid/callback').replace(
      queryParameters: {
        'state': _state,
        'code': code,
        'code_verifier': _verifier,
      },
    );
    final response = await _http.send('GET', callback);
    if (response.statusCode == 200) {
      final data = jsonDecode(response.body) as Map<String, dynamic>;
      return SsoDone(data);
    }
    final target = SsoHttp.redirectTarget(callback, response);
    // Failures end on the web login page with ?error=..., "Unauthorized"
    // when no account matches.
    final error = target?.queryParameters['error'];
    if (error == 'Unauthorized') throw const SsoException(SsoError.noAccount);
    throw SsoException(
      SsoError.failed,
      error ?? 'callback ${response.statusCode}',
    );
  }

  static bool _isRedirectUri(Uri url) =>
      url.toString().startsWith(ssoRedirectUri);

  static String _random(int bytes) {
    final random = Random.secure();
    return base64Url
        .encode(List<int>.generate(bytes, (_) => random.nextInt(256)))
        .replaceAll('=', '');
  }
}
