import 'dart:convert';

import 'package:abs_wear/login/data/sso/sso_http.dart';
import 'package:abs_wear/login/data/sso/sso_types.dart';
import 'package:http/http.dart' as http;

/// tinyauth's login, through the JSON API its own web interface uses. Its
/// OpenID provider sends the browser to `/oidc/authorize?oidc_ticket=...`;
/// the watch logs in with `/api/user/login` (and `/api/user/totp`), then
/// trades the ticket for the redirect back at `/api/oidc/authorize-complete`.
/// Local (and LDAP) users only: logins through another OAuth provider are
/// that provider's pages.
class TinyauthAdapter implements IdpAdapter {
  TinyauthAdapter(IdpContext context)
    : _http = context.http,
      _follow = context.follow;

  /// The adapter for [page] if it is tinyauth's authorize (or error) page.
  static IdpAdapter? forPage(SsoPage page, IdpContext context) =>
      matches(page) ? TinyauthAdapter(context) : null;

  final SsoHttp _http;
  final FollowRedirects _follow;

  @override
  String get name => 'Tinyauth';

  /// The page the provider showed, for the API's address.
  late Uri _page;
  late String _ticket;
  String _app = 'Audiobookshelf';
  String? _user;
  _Screen _screen = _Screen.login;

  @override
  Uri? redirect;

  /// tinyauth's web interface (one page for every screen, "Tinyauth" in
  /// its head) at `/oidc/authorize` with a ticket, or at `/error`.
  static bool matches(SsoPage page) {
    final url = page.url;
    final q = url.queryParameters;
    final screen = switch (url.path) {
      '/oidc/authorize' =>
        q['login_for'] == 'oidc' && (q['oidc_ticket'] ?? '').isNotEmpty,
      '/error' => true,
      _ => false,
    };
    return screen && page.body.contains('content="Tinyauth"');
  }

  @override
  Future<SsoStep> begin(SsoPage page) async {
    _page = page.url;
    final q = _page.queryParameters;
    if (_page.path == '/error') {
      // E.g. the server's redirect URI isn't one of the client's.
      throw SsoException(SsoError.failed, 'tinyauth: ${q['error']}');
    }
    _ticket = q['oidc_ticket']!;
    final app = q['oidc_name'];
    if (app != null && app.isNotEmpty) _app = app;
    final context = await _get('context/app');
    final providers = [
      for (final p in (context['auth'] as Map?)?['providers'] as List? ?? [])
        (p as Map<String, dynamic>)['id'],
    ];
    final auto = (context['oauth'] as Map?)?['autoRedirect'] as String? ?? '';
    // Without local or LDAP users (or when tinyauth sends everyone straight
    // to an OAuth provider) there is no password form.
    if (!providers.contains('local') && !providers.contains('ldap')) {
      throw SsoException(SsoError.unsupportedStep, providers.join(','));
    }
    if (auto.isNotEmpty && providers.contains(auto)) {
      throw SsoException(SsoError.unsupportedStep, auto);
    }
    return const SsoPrompt([SsoField.username, SsoField.password]);
  }

  @override
  Future<SsoStep?> submit(Map<SsoField, String> answer) async {
    switch (_screen) {
      case _Screen.login:
        final user = answer[SsoField.username] ?? '';
        final r = await _post('user/login', {
          'username': user,
          'password': answer[SsoField.password] ?? '',
        });
        if (r.statusCode == 401) {
          return const SsoPrompt([
            SsoField.username,
            SsoField.password,
          ], retry: true);
        }
        _user = user;
        if (_json(_check(r))['totpPending'] == true) {
          _screen = _Screen.totp;
          return SsoPrompt([SsoField.code], user: _user);
        }
        return await _consent();
      case _Screen.totp:
        final r = await _post('user/totp', {
          'code': answer[SsoField.code] ?? '',
        });
        if (r.statusCode == 401) {
          return SsoPrompt([SsoField.code], user: _user, retry: true);
        }
        _check(r);
        return await _consent();
      case _Screen.consent:
        return await _complete();
    }
  }

  /// The consent screen, unless the user already allowed this app (then
  /// straight back to the server).
  Future<SsoStep?> _consent() async {
    final r = await _http.send(
      'GET',
      _api('oidc/skip-consent', {'oidc_ticket': _ticket}),
    );
    if (r.statusCode == 200 && _json(r)['skipConsent'] == true) {
      return await _complete();
    }
    _screen = _Screen.consent;
    return SsoConsent(_app);
  }

  /// Allows the app; tinyauth answers with where the browser goes next.
  /// Null once that is the redirect back to the server ([redirect] set).
  Future<SsoStep?> _complete() async {
    final r = _check(
      await _post('oidc/authorize-complete', {'ticket': _ticket}),
    );
    final to = _page.resolve(_json(r)['redirect_uri'] as String? ?? '');
    final here =
        to.scheme == _page.scheme &&
        to.host == _page.host &&
        to.port == _page.port;
    if (here && to.path == '/error') {
      // An expired ticket, for one.
      throw SsoException(
        SsoError.failed,
        'tinyauth: ${to.queryParameters['error']}',
      );
    }
    final (page, back) = await _follow(to);
    if (back != null) {
      redirect = back;
      return null;
    }
    throw SsoException(SsoError.unsupportedStep, page?.url.path);
  }

  Uri _api(String path, [Map<String, String>? query]) =>
      _page.resolve('/api/$path').replace(queryParameters: query);

  Future<Map<String, dynamic>> _get(String path) async =>
      _json(_check(await _http.send('GET', _api(path))));

  Future<http.Response> _post(String path, Map<String, String> body) =>
      _http.send('POST', _api(path), body: body);

  /// [r] if it succeeded. A 429 is tinyauth's lockout after too many wrong
  /// passwords or codes.
  static http.Response _check(http.Response r) {
    if (r.statusCode == 200) return r;
    final path = r.request?.url.path;
    if (r.statusCode == 429) {
      throw SsoException(SsoError.failed, 'tinyauth: locked out ($path)');
    }
    throw SsoException(SsoError.failed, 'tinyauth ${r.statusCode} at $path');
  }

  static Map<String, dynamic> _json(http.Response r) {
    try {
      return jsonDecode(r.body) as Map<String, dynamic>;
    } on FormatException {
      throw const SsoException(SsoError.failed, 'tinyauth: not JSON');
    }
  }
}

enum _Screen { login, totp, consent }
