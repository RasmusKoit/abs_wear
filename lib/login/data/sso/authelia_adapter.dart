import 'dart:convert';

import 'package:abs_wear/login/data/sso/sso_http.dart';
import 'package:abs_wear/login/data/sso/sso_types.dart';
import 'package:http/http.dart' as http;

/// Authelia's login, through the JSON API its own portal uses
/// (`/api/firstfactor`, `/api/secondfactor/totp`, `/api/oidc/consent`).
/// The portal page only carries the OpenID Connect flow's id; each API
/// answer becomes a native [SsoStep].
class AutheliaAdapter implements IdpAdapter {
  AutheliaAdapter(IdpContext context, this._api)
    : _http = context.http,
      _follow = context.follow;

  /// The adapter for [page] if it is Authelia's portal during an OpenID
  /// Connect login.
  static IdpAdapter? forPage(SsoPage page, IdpContext context) =>
      matches(page) ? AutheliaAdapter(context, _apiBase(page)) : null;

  final SsoHttp _http;
  final FollowRedirects _follow;

  /// Where the portal is served (its `<base href>`), the API under it.
  final Uri _api;

  @override
  String get name => 'Authelia';

  _Screen _screen = _Screen.login;
  String _flowId = '';
  String? _user;
  String _clientId = '';
  List<String> _claims = const [];

  @override
  Uri? redirect;

  /// Authelia sends the browser to its portal with `flow=openid_connect`
  /// and the flow's id; the portal's HTML is Authelia's React app, its
  /// settings on `<body>`. (The name "Authelia" is only in a licence
  /// comment, which a minifying proxy may strip.)
  static bool matches(SsoPage page) {
    final q = page.url.queryParameters;
    return q['flow'] == 'openid_connect' &&
        (q['flow_id']?.isNotEmpty ?? false) &&
        _portalMarkers.every(page.body.contains);
  }

  static const _portalMarkers = [
    'data-basepath=',
    'data-rememberme=',
    'data-resetpassword=',
  ];

  static final _baseHref = RegExp('<base href="([^"]+)"');

  /// The portal's root: `<base href>`, else the page's directory. Never
  /// another server: the password goes to the API under it.
  static Uri _apiBase(SsoPage page) {
    final href = _baseHref.firstMatch(page.body)?.group(1);
    final base = href == null ? null : page.url.resolve(href);
    final url = page.url;
    final sameServer =
        base != null &&
        base.scheme == url.scheme &&
        base.host == url.host &&
        base.port == url.port;
    return (sameServer ? base : url).resolve('./');
  }

  @override
  Future<SsoStep> begin(SsoPage page) async => await _pageStep(page);

  @override
  Future<SsoStep?> submit(Map<SsoField, String> answer) async {
    switch (_screen) {
      case _Screen.login:
        _user = answer[SsoField.username]?.trim() ?? _user;
        final r = await _post('api/firstfactor', {
          'username': _user ?? '',
          'password': answer[SsoField.password] ?? '',
          'keepMeLoggedIn': false,
          'flow': 'openid_connect',
          'flowID': _flowId,
        });
        if (r.statusCode == 401) {
          return const SsoPrompt([
            SsoField.username,
            SsoField.password,
          ], retry: true);
        }
        // With a second factor still to go, there is no redirect yet.
        return switch (_data(r)) {
          {'redirect': final String to} => await _continue(_api.resolve(to)),
          {'redirect': _?} => throw const SsoException(
            SsoError.failed,
            'authelia: bad redirect',
          ),
          _ => await _secondFactor(),
        };
      case _Screen.totp:
        final r = await _post('api/secondfactor/totp', {
          'token': answer[SsoField.code]?.trim() ?? '',
          'flow': 'openid_connect',
          'flowID': _flowId,
        });
        // A wrong code is a 403 here (a wrong password a 401), a code that
        // isn't 6 or 8 digits long a 400.
        if (const {400, 401, 403}.contains(r.statusCode)) {
          return SsoPrompt([SsoField.code], user: _user, retry: true);
        }
        return await _continue(_redirect(_data(r), 'redirect'));
      case _Screen.consent:
        final r = await _post('api/oidc/consent', {
          'flow_id': _flowId,
          'client_id': _clientId,
          'consent': true,
          'pre_configure': false,
          if (_claims.isNotEmpty) 'claims': _claims,
        });
        return await _continue(_redirect(_data(r), 'redirect_uri'));
    }
  }

  /// The screen for a portal [page]: the login form or the consent screen.
  Future<SsoStep> _pageStep(SsoPage page) async {
    final flowId = page.url.queryParameters['flow_id'];
    if (flowId == null || flowId.isEmpty) {
      throw SsoException(SsoError.unsupportedStep, page.url.path);
    }
    _flowId = flowId;
    final path = page.url.path;
    if (path.endsWith('/consent/openid/decision')) return await _consent();
    // Anything else under /consent (e.g. a forced re-login) or elsewhere
    // isn't a screen the watch knows.
    if (page.url.resolve('./') != _api || path.contains('/consent/')) {
      throw SsoException(SsoError.unsupportedStep, path);
    }
    _screen = _Screen.login;
    return const SsoPrompt([SsoField.username, SsoField.password]);
  }

  /// After the password: the second factor the account has. Only TOTP can
  /// be typed on the watch; WebAuthn and Duo push are unsupported.
  Future<SsoStep> _secondFactor() async {
    // The POST reads the user's methods from storage (the GET may answer
    // from the session, made before they were known).
    final info = _data(await _post('api/user/info', const {}));
    final config = _data(await _send('GET', 'api/configuration'));
    final methods = switch (config['available_methods']) {
      final List<dynamic> list => list,
      _ => const <dynamic>[],
    };
    if (info['has_totp'] == true && methods.contains('totp')) {
      _screen = _Screen.totp;
      return SsoPrompt([SsoField.code], user: _user);
    }
    throw SsoException(SsoError.unsupportedStep, switch (info) {
      {'has_webauthn': true} => 'webauthn',
      {'has_duo': true} => 'duo',
      _ => 'no second factor',
    });
  }

  /// The consent screen: which app asks, and the claims to grant it.
  Future<SsoStep> _consent() async {
    final consent = _data(
      await _send('GET', 'api/oidc/consent', query: {'flow_id': _flowId}),
    );
    if (consent['require_login'] == true) {
      throw const SsoException(SsoError.unsupportedStep, 'require_login');
    }
    _clientId = _string(consent['client_id']) ?? '';
    _claims = [
      for (final key in const ['essential_claims', 'claims'])
        if (consent[key] case final List<dynamic> list)
          ...list.whereType<String>(),
    ];
    _screen = _Screen.consent;
    final app = _string(consent['client_description']);
    return SsoConsent(app == null || app.isEmpty ? _clientId : app);
  }

  /// The redirect in an API answer's [key], resolved under the portal.
  Uri _redirect(Map<String, dynamic> data, String key) => switch (data[key]) {
    final String to => _api.resolve(to),
    _ => throw SsoException(SsoError.failed, 'authelia: no $key'),
  };

  static String? _string(Object? value) => value is String ? value : null;

  /// Follows Authelia's redirect [to]: back to the server (null, [redirect]
  /// set) or to another portal screen.
  Future<SsoStep?> _continue(Uri to) async {
    final (page, back) = await _follow(to);
    if (back != null) {
      redirect = back;
      return null;
    }
    return await _pageStep(page!);
  }

  Future<http.Response> _post(String path, Map<String, Object?> body) =>
      _send('POST', path, body: body);

  Future<http.Response> _send(
    String method,
    String path, {
    Map<String, Object?>? body,
    Map<String, String>? query,
  }) => _http.send(
    method,
    _api.resolve(path).replace(queryParameters: query),
    body: body,
  );

  /// The `data` of a successful API answer.
  static Map<String, dynamic> _data(http.Response r) {
    Object? json;
    try {
      json = jsonDecode(r.body);
    } on FormatException {
      json = null;
    }
    if (r.statusCode != 200 ||
        json is! Map<String, dynamic> ||
        json['status'] != 'OK') {
      final message = json is Map<String, dynamic> ? json['message'] : null;
      throw SsoException(
        SsoError.failed,
        'authelia ${r.statusCode}${message == null ? '' : ': $message'}',
      );
    }
    return switch (json['data']) {
      final Map<String, dynamic> data => data,
      null => const {},
      _ => throw const SsoException(SsoError.failed, 'authelia: bad data'),
    };
  }
}

enum _Screen { login, totp, consent }
