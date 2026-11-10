import 'dart:convert';

import 'package:abs_wear/login/data/sso/sso_http.dart';
import 'package:abs_wear/login/data/sso/sso_types.dart';
import 'package:http/http.dart' as http;

/// Logto's sign-in, through its Experience API (`/api/experience`): the
/// JSON its own sign-in app uses. A password sign-in, a TOTP code when the
/// account has one, and the consent screen of third-party apps.
class LogtoAdapter implements IdpAdapter {
  LogtoAdapter(IdpContext context)
    : _http = context.http,
      _follow = context.follow;

  /// The adapter for [page] if it is Logto's sign-in app.
  static IdpAdapter? forPage(SsoPage page, IdpContext context) =>
      matches(page, context.http) ? LogtoAdapter(context) : null;

  final SsoHttp _http;
  final FollowRedirects _follow;

  @override
  String get name => 'Logto';

  /// The sign-in page: Logto's API is on the same server.
  late Uri _page;
  _Stage _stage = _Stage.password;
  List<SsoField> _fields = const [];

  /// Email addresses work as well as usernames.
  bool _email = false;
  String? _user;

  /// The optional prompts at `submit` already skipped (each only once).
  final Set<String> _skipped = {};

  @override
  Uri? redirect;

  /// Logto's sign-in app embeds its settings as `window.logtoSsr`; Logto's
  /// OIDC provider sets the `_logto` cookie before sending the user there.
  static bool matches(SsoPage page, SsoHttp http) =>
      page.body.contains('window.logtoSsr') ||
      http.cookie(page.url, '_logto') != null;

  @override
  Future<SsoStep> begin(SsoPage page) async {
    _page = page.url;
    final settings = _json(
      await _http.send('GET', _api('.well-known/sign-in-exp')),
    );
    // A CAPTCHA needs the provider's script in a browser.
    if ((settings['captchaPolicy'] as Map?)?['enabled'] == true) {
      throw const SsoException(SsoError.unsupportedStep, 'captcha');
    }
    // Terms the user has to tick: Logto's sign-in app asks for them, its API
    // doesn't, so signing in here would skip them.
    if (settings['agreeToTermsPolicy'] == 'Manual' &&
        (_set(settings['termsOfUseUrl']) ||
            _set(settings['privacyPolicyUrl']))) {
      throw const SsoException(SsoError.unsupportedStep, 'terms');
    }
    final identifiers = [
      for (final m in ((settings['signIn'] as Map?)?['methods'] as List?) ?? [])
        if ((m as Map)['password'] == true) m['identifier'],
    ];
    _fields = [
      if (identifiers.contains('username'))
        SsoField.username
      else if (identifiers.contains('email'))
        SsoField.email
      else
        throw SsoException(SsoError.unsupportedStep, 'sign-in: $identifiers'),
      SsoField.password,
    ];
    _email = identifiers.contains('email');
    final start = await _http.send(
      'PUT',
      _api('experience'),
      body: {'interactionEvent': 'SignIn'},
    );
    _check(start);
    return SsoPrompt(_fields);
  }

  @override
  Future<SsoStep?> submit(Map<SsoField, String> answer) async {
    switch (_stage) {
      case _Stage.password:
        return await _password(answer);
      case _Stage.totp:
        final r = await _http.send(
          'POST',
          _api('experience/verification/totp/verify'),
          body: {'code': answer[SsoField.code] ?? ''},
        );
        if (_code(r) == 'session.mfa.invalid_totp_code') {
          return SsoPrompt(const [SsoField.code], user: _user, retry: true);
        }
        _check(r);
        return await _submit();
      case _Stage.consent:
        final r = await _http.send(
          'POST',
          _api('interaction/consent'),
          body: const <String, dynamic>{},
        );
        return await _redirectTo(_json(r));
    }
  }

  /// Checks the username (or email) and password, then signs in.
  Future<SsoStep?> _password(Map<SsoField, String> answer) async {
    final id = answer[SsoField.username] ?? answer[SsoField.email] ?? '';
    final r = await _http.send(
      'POST',
      _api('experience/verification/password'),
      body: {
        'identifier': {
          // Logto usernames can't contain "@".
          'type': _email && id.contains('@') ? 'email' : 'username',
          'value': id,
        },
        'password': answer[SsoField.password] ?? '',
      },
    );
    // Logto doesn't say whether the user or the password was wrong.
    if (_code(r) == 'session.invalid_credentials') {
      return SsoPrompt(_fields, retry: true);
    }
    final verification = _json(r);
    _check(
      await _http.send(
        'POST',
        _api('experience/identification'),
        body: {'verificationId': verification['verificationId']},
      ),
    );
    _user = id;
    return await _submit();
  }

  /// Finishes the sign-in, or asks for what Logto still needs.
  Future<SsoStep?> _submit() async {
    final r = await _http.send('POST', _api('experience/submit'));
    final code = _code(r);
    final data = _data(r);
    switch (code) {
      case null:
        return await _redirectTo(_json(r));
      case 'session.mfa.require_mfa_verification':
        final factors = (data['availableFactors'] as List?) ?? const [];
        // Email and SMS codes would need sending first; passkeys need a
        // browser.
        if (!factors.contains('Totp')) {
          throw SsoException(SsoError.unsupportedStep, 'mfa: $factors');
        }
        _stage = _Stage.totp;
        return SsoPrompt(const [SsoField.code], user: _user);
      // "Add MFA to your account?" and "Add a passkey?": optional prompts
      // the user may skip, as setting either up belongs on a bigger screen.
      // Logto saves the skip to the user's account (`logto_config`), so it
      // stops asking in browsers too, the same as "Skip" there.
      case 'user.suggest_mfa' when _skipped.add('mfa'):
        return await _skip('experience/profile/mfa/mfa-skipped');
      case 'user.passkey_preferred' when _skipped.add('passkey'):
        return await _skip('experience/profile/mfa/passkey-skipped');
      // Anything else Logto wants first is for a browser: setting up MFA,
      // even when skippable (the admin asked for it), more MFA factors, a
      // missing profile field, ...
      default:
        if (r.statusCode == 403 || r.statusCode == 422) {
          throw SsoException(SsoError.unsupportedStep, code);
        }
        _check(r);
        throw SsoException(SsoError.failed, 'logto: $code');
    }
  }

  /// Skips an optional prompt with [path], then submits again.
  Future<SsoStep?> _skip(String path) async {
    _check(await _http.send('POST', _api(path)));
    return await _submit();
  }

  /// Follows Logto's redirect back towards the server. Null once it gets
  /// there ([redirect] set); a consent screen for third-party apps.
  Future<SsoStep?> _redirectTo(Map<String, dynamic> body) async {
    final to = body['redirectTo'];
    if (to is! String) {
      throw const SsoException(SsoError.failed, 'logto: no redirect');
    }
    final (page, back) = await _follow(_page.resolve(to));
    if (back != null) {
      redirect = back;
      return null;
    }
    if (page != null && page.url.path == '/consent') {
      final consent = _json(
        await _http.send('GET', _api('interaction/consent')),
      );
      // Picking an organization isn't something the watch can show.
      if (((consent['organizations'] as List?) ?? const []).isNotEmpty) {
        throw const SsoException(SsoError.unsupportedStep, 'organizations');
      }
      _stage = _Stage.consent;
      final app = (consent['application'] as Map?)?['name'] as String?;
      return SsoConsent(app ?? 'Audiobookshelf');
    }
    throw SsoException(SsoError.unsupportedStep, page?.url.path);
  }

  Uri _api(String path) => _page.resolve('/api/$path');

  static bool _set(Object? url) => url is String && url.isNotEmpty;

  /// Throws for an error [response].
  static void _check(http.Response response) {
    final status = response.statusCode;
    if (status >= 200 && status < 300) return;
    final code = _code(response);
    if (code != null && code.startsWith('session.captcha')) {
      throw SsoException(SsoError.unsupportedStep, code);
    }
    // Suspended or banned.
    if (status == 401) throw SsoException(SsoError.accessDenied, code);
    throw SsoException(SsoError.failed, 'logto $status: $code');
  }

  /// The JSON object in a successful [response].
  static Map<String, dynamic> _json(http.Response response) {
    _check(response);
    try {
      return jsonDecode(response.body) as Map<String, dynamic>;
    } on Object {
      throw const SsoException(SsoError.failed, 'logto: not JSON');
    }
  }

  /// Logto's error code (`session.invalid_credentials`, ...), if any.
  static String? _code(http.Response response) =>
      _error(response)?['code'] as String?;

  static Map<String, dynamic> _data(http.Response response) =>
      (_error(response)?['data'] as Map?)?.cast<String, dynamic>() ?? const {};

  static Map<String, dynamic>? _error(http.Response response) {
    if (response.statusCode < 400) return null;
    try {
      return jsonDecode(response.body) as Map<String, dynamic>;
    } on Object {
      return null;
    }
  }
}

enum _Stage { password, totp, consent }
