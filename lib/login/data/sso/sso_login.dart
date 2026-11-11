import 'dart:convert';
import 'dart:math';

import 'package:abs_wear/login/data/sso/idp_adapters.dart';
import 'package:abs_wear/login/data/sso/sso_http.dart';
import 'package:abs_wear/login/data/sso/sso_types.dart';
import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;

export 'sso_types.dart';

/// One SSO login on the watch, from the server's `/auth/openid` to its
/// callback, with the identity provider's screens shown natively in between.
///
/// Call [start], show each returned [SsoStep] and pass the answers to
/// [submit] until it returns [SsoDone]. [close] when finished or cancelled.
class SsoLogin {
  SsoLogin._(this.serverUrl, this._http, [this._redirectUri = ssoRedirectUri]);

  /// [serverUrl] without a trailing slash, as for password login.
  final String serverUrl;
  final SsoHttp _http;
  late final String _state = _random(24);
  late final String _verifier = _random(48);

  /// Where the identity provider's answer goes: [ssoRedirectUri] when the
  /// watch drives the login, the Wear OS relay when the phone does.
  final String _redirectUri;
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

  /// Starts an SSO login to finish in the paired phone's browser: checks
  /// the server and makes the watch's own `/auth/openid` call with
  /// [redirectUri] (the Wear OS relay), so the server's session cookie
  /// stays here. Returns the identical URL for the phone to open; pass
  /// the phone's answer to [finishOnPhone].
  static Future<(SsoLogin, Uri)> startOnPhone(
    String serverUrl, {
    required String redirectUri,
    http.Client? client,
  }) async {
    final login = SsoLogin._(serverUrl, SsoHttp(client), redirectUri);
    try {
      await login._checkServer();
      final start = login._startUrl();
      await login._start(start);
      return (login, start);
    } on Object {
      login.close();
      rethrow;
    }
  }

  /// Finishes a login from [startOnPhone] with the phone's [responseUrl]
  /// (the relay URL carrying the code and state).
  Future<SsoStep> finishOnPhone(Uri responseUrl) => _finish(responseUrl);

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
    final target = await _start(_startUrl());
    // Into the identity provider, up to its first login page.
    final (page, back) = await _follow(target);
    if (back != null) {
      // Already signed in there: straight back to the server.
      return await _finish(back);
    }
    final idp = _adapterFor(page!);
    if (idp == null) {
      // Origin and path only: the query holds the login's state.
      throw SsoException(
        SsoError.unsupportedProvider,
        page.url.replace(query: '').toString(),
      );
    }
    _idp = idp;
    return await idp.begin(page);
  }

  /// The server's `/auth/openid` URL for this login.
  Uri _startUrl() {
    final challenge = base64Url
        .encode(sha256.convert(utf8.encode(_verifier)).bytes)
        .replaceAll('=', '');
    return Uri.parse('$serverUrl/auth/openid').replace(
      queryParameters: {
        'response_type': 'code',
        'redirect_uri': _redirectUri,
        'code_challenge': challenge,
        'code_challenge_method': 'S256',
        'state': _state,
        'client_id': 'abs-wear',
      },
    );
  }

  /// Calls [start] (keeping the server's session cookie) and returns where
  /// the server sends the browser: the identity provider.
  Future<Uri> _start(Uri start) async {
    final response = await _http.send('GET', start);
    final target = SsoHttp.redirectTarget(start, response);
    if (target != null) return target;
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

  /// Follows redirects from [url] until a page (returned first) or the
  /// redirect back to the watch (returned second).
  Future<(SsoPage?, Uri?)> _follow(Uri url) async {
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
        return (SsoPage(current, response.body), null);
      }
      current = next;
    }
    throw const SsoException(SsoError.failed, 'too many redirects');
  }

  /// The first adapter in [idpAdapters] that recognises [page].
  IdpAdapter? _adapterFor(SsoPage page) {
    final context = IdpContext(_http, _follow);
    for (final make in idpAdapters) {
      if (make(page, context) case final adapter?) return adapter;
    }
    return null;
  }

  /// From the identity provider's last redirect back to the server, to the
  /// redirect to [ssoRedirectUri], then the code exchange.
  Future<SsoStep> _finish(Uri from) async {
    final (page, back) = await _follow(from);
    if (back == null) {
      // A page instead of the redirect back, e.g. an error page.
      throw SsoException(SsoError.failed, 'stopped at ${page?.url.path}');
    }
    final query = back.queryParameters;
    final code = query['code'];
    if (!_isOurState(query['state'])) {
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

  bool _isRedirectUri(Uri url) => url.toString().startsWith(_redirectUri);

  /// Whether [state] is this login's. On the phone, a companion app (e.g.
  /// OHealth) appends `_sch_` and its own address to the state; Google's
  /// relay page strips that again, but a redirect straight to the companion
  /// brings it back here. The random part must still match exactly.
  bool _isOurState(String? state) =>
      state == _state || (state?.startsWith('${_state}_sch_') ?? false);

  static String _random(int bytes) {
    final random = Random.secure();
    return base64Url
        .encode(List<int>.generate(bytes, (_) => random.nextInt(256)))
        .replaceAll('=', '');
  }
}
