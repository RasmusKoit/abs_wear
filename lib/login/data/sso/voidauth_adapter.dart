import 'dart:convert';

import 'package:abs_wear/login/data/sso/sso_http.dart';
import 'package:abs_wear/login/data/sso/sso_types.dart';
import 'package:http/http.dart' as http;

/// VoidAuth's login, through the JSON interaction API its own web app uses
/// (`/api/interaction/...`, node-oidc-provider underneath). VoidAuth
/// redirects to its app's pages (`/login`, `/mfa`, `/consent/<uid>`); each
/// becomes a native [SsoStep] and the answers go to the matching API call.
class VoidAuthAdapter implements IdpAdapter {
  VoidAuthAdapter(this._base, IdpContext context)
    : _http = context.http,
      _follow = context.follow;

  /// The adapter for [page] if it is VoidAuth's login page.
  static IdpAdapter? forPage(SsoPage page, IdpContext context) {
    final base = appBase(page);
    if (base == null || _route(page.url, base) != 'login') return null;
    return VoidAuthAdapter(base, context);
  }

  final SsoHttp _http;
  final FollowRedirects _follow;

  /// Where VoidAuth's app lives (its `APP_URL`, with a trailing slash).
  final Uri _base;
  _Screen _screen = _Screen.login;
  String? _user;
  String? _consentUid;

  @override
  String get name => 'VoidAuth';

  @override
  Uri? redirect;

  /// The app's base URL if [page] is VoidAuth's Angular app: an `<app-root>`
  /// with its generated theme and logo meta tag (the title is configurable).
  static Uri? appBase(SsoPage page) {
    final html = page.body;
    if (!html.contains('<app-root') ||
        !html.contains('generated-mat-theme.css') ||
        !html.contains('name="logoUri"')) {
      return null;
    }
    final href = RegExp(r'<base\s+href="([^"]*)"').firstMatch(html)?[1];
    final base = page.url.resolve(href ?? '/');
    // The password goes to the API at the base: only the page's own server.
    return base.origin == page.url.origin ? base : null;
  }

  /// The app route of [url] below [base] (`login`, `mfa`, `consent/<uid>`).
  static String? _route(Uri url, Uri base) {
    final path = url.path;
    if (!path.startsWith(base.path)) return null;
    return path.substring(base.path.length);
  }

  Uri _api(String path) => _base.resolve('api/interaction/$path');

  @override
  Future<SsoStep> begin(SsoPage page) async =>
      const SsoPrompt([SsoField.username, SsoField.password]);

  @override
  Future<SsoStep?> submit(Map<SsoField, String> answer) async {
    switch (_screen) {
      case _Screen.login:
        final user = answer[SsoField.username] ?? '';
        final response = await _http.send(
          'POST',
          _api('login'),
          body: {'input': user, 'password': answer[SsoField.password] ?? ''},
        );
        if (response.statusCode == 401) {
          return const SsoPrompt([
            SsoField.username,
            SsoField.password,
          ], retry: true);
        }
        _user = user;
        return await _next(_location(response));
      case _Screen.totp:
        final response = await _http.send(
          'POST',
          _api('totp'),
          body: {'token': answer[SsoField.code] ?? ''},
        );
        if (response.statusCode == 401) {
          return SsoPrompt([SsoField.code], user: _user, retry: true);
        }
        return await _next(_location(response));
      case _Screen.consent:
        final confirm = _api('$_consentUid/confirm/');
        final response = await _http.send('POST', confirm);
        final to = SsoHttp.redirectTarget(confirm, response);
        if (to == null) throw _failed(response);
        return await _next(to);
    }
  }

  /// Where a login or TOTP answer says to go on (`{"location": ...}`).
  Uri _location(http.Response response) {
    if (response.statusCode != 200) throw _failed(response);
    try {
      final json = jsonDecode(response.body) as Map<String, dynamic>;
      return _base.resolve(json['location'] as String);
    } on Object {
      throw const SsoException(SsoError.failed, 'voidauth: no location');
    }
  }

  /// Follows VoidAuth from [url] to its next page. Null once it sends the
  /// user back to the server ([redirect] set).
  Future<SsoStep?> _next(Uri url) async {
    final (page, back) = await _follow(url);
    if (back != null) {
      redirect = back;
      return null;
    }
    final route = _route(page!.url, _base) ?? page.url.path;
    switch (route.split('/')) {
      case ['mfa']:
        return await _mfa();
      case ['consent', final uid]:
        _screen = _Screen.consent;
        _consentUid = uid;
        return SsoConsent(await _clientName(uid) ?? 'Audiobookshelf');
      case ['approval_required' || 'user_expired' || 'forbidden']:
        throw SsoException(SsoError.accessDenied, route);
      default:
        // Email verification, a sign-up form, an error page, ...
        throw SsoException(SsoError.unsupportedStep, route);
    }
  }

  /// The second factor. Only a TOTP can be typed in: passkeys, and setting
  /// up a first second factor, need VoidAuth's web app.
  Future<SsoStep> _mfa() async {
    final response = await _http.send('GET', _base.resolve('api/user/me'));
    if (response.statusCode != 200) throw _failed(response);
    final me = jsonDecode(response.body) as Map<String, dynamic>;
    if (me['hasTotp'] != true) {
      throw SsoException(
        SsoError.unsupportedStep,
        me['hasPasskeys'] == true ? 'passkey' : 'mfa setup',
      );
    }
    _screen = _Screen.totp;
    return SsoPrompt([SsoField.code], user: _user);
  }

  Future<String?> _clientName(String uid) async {
    final response = await _http.send('GET', _api('$uid/detail'));
    if (response.statusCode != 200) return null;
    try {
      final detail = jsonDecode(response.body) as Map<String, dynamic>;
      return detail['clientName'] as String?;
    } on FormatException {
      return null;
    }
  }

  static SsoException _failed(http.Response response) {
    // 419: the login took too long; 423: too many wrong codes.
    return SsoException(SsoError.failed, 'voidauth ${response.statusCode}');
  }
}

enum _Screen { login, totp, consent }
