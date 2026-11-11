import 'dart:convert';

import 'package:abs_wear/login/data/sso/sso_http.dart';
import 'package:abs_wear/login/data/sso/sso_types.dart';
import 'package:http/http.dart' as http;

/// Authentik's login, through its flow executor API: the JSON its own web
/// interface uses (`/api/v3/flows/executor/<flow>/`). Each stage's challenge
/// becomes a native [SsoStep]; the answers go back as the stage's JSON.
class AuthentikAdapter implements IdpAdapter {
  AuthentikAdapter(IdpContext context)
    : _http = context.http,
      _follow = context.follow;

  /// The adapter for [page] if it is one of Authentik's flows.
  static IdpAdapter? forPage(SsoPage page, IdpContext context) =>
      matches(page.url) ? AuthentikAdapter(context) : null;

  final SsoHttp _http;
  final FollowRedirects _follow;

  @override
  String get name => 'Authentik';

  /// The flow executor of the current flow.
  late Uri _executor;
  Map<String, dynamic> _challenge = const {};
  String? _user;
  String _app = 'Audiobookshelf';

  @override
  Uri? redirect;

  /// Authentik shows its flows at `/if/flow/<slug>/`.
  static bool matches(Uri page) {
    final s = page.pathSegments;
    return s.length >= 3 && s[0] == 'if' && s[1] == 'flow' && s[2].isNotEmpty;
  }

  @override
  Future<SsoStep> begin(SsoPage page) async {
    final step = await _enter(page.url);
    if (step == null) {
      // A flow with nothing to ask (e.g. implicit consent) went straight on.
      throw const SsoException(SsoError.failed, 'flow had no steps');
    }
    return step;
  }

  /// Starts the flow shown at [page]. Null once Authentik sends the user
  /// back to the server ([redirect] set).
  Future<SsoStep?> _enter(Uri page) async {
    final slug = page.pathSegments[2];
    _executor = page.replace(
      pathSegments: ['api', 'v3', 'flows', 'executor', slug, ''],
      // The executor gets the page's own query (next=..., the OAuth params).
      queryParameters: {'query': page.query},
    );
    final response = await _http.send('GET', _executor);
    return await _handle(await _challengeFrom(response));
  }

  @override
  Future<SsoStep?> submit(Map<SsoField, String> answer) async {
    final component = _challenge['component'] as String?;
    final body = switch (component) {
      'ak-stage-identification' => {
        'uid_field': answer[SsoField.username] ?? '',
        'password': ?answer[SsoField.password],
      },
      'ak-stage-password' => {'password': answer[SsoField.password] ?? ''},
      'ak-stage-authenticator-validate' => {
        'code': answer[SsoField.code] ?? '',
      },
      'ak-stage-consent' => {'token': _challenge['token']},
      _ => throw SsoException(SsoError.unsupportedStep, component),
    };
    return await _handle(await _post({'component': component, ...body}));
  }

  Future<Map<String, dynamic>> _post(Map<String, dynamic> body) async {
    final csrf = _http.cookie(_executor, 'authentik_csrf');
    final response = await _http.send(
      'POST',
      _executor,
      body: body,
      headers: {'X-authentik-CSRF': ?csrf},
    );
    return await _challengeFrom(response);
  }

  /// The challenge in [response]. A POST is answered with a redirect to the
  /// executor, which then serves the next challenge.
  Future<Map<String, dynamic>> _challengeFrom(http.Response response) async {
    var r = response;
    var url = _executor;
    for (var i = 0; i < 5; i++) {
      final next = SsoHttp.redirectTarget(url, r);
      if (next == null) break;
      url = next;
      r = await _http.send('GET', url);
    }
    if (r.statusCode != 200) {
      throw SsoException(SsoError.failed, 'authentik ${r.statusCode}');
    }
    try {
      return jsonDecode(r.body) as Map<String, dynamic>;
    } on FormatException {
      throw const SsoException(SsoError.failed, 'authentik: not JSON');
    }
  }

  /// Turns a challenge into the next step, answering the ones the user
  /// needn't see. Null once Authentik sends the user back to the server.
  Future<SsoStep?> _handle(Map<String, dynamic> challenge) async {
    _challenge = challenge;
    final component = challenge['component'] as String?;
    final errors = challenge['response_errors'] as Map<String, dynamic>?;
    final retry = errors != null && errors.isNotEmpty;
    switch (component) {
      case 'ak-stage-identification':
        if (challenge['captcha_stage'] != null) {
          throw const SsoException(SsoError.unsupportedStep, 'captcha');
        }
        _app = challenge['application_pre'] as String? ?? _app;
        return SsoPrompt([
          SsoField.username,
          if (challenge['password_fields'] == true) SsoField.password,
        ], retry: retry);
      case 'ak-stage-password':
        _user = challenge['pending_user'] as String? ?? _user;
        return SsoPrompt([SsoField.password], user: _user, retry: retry);
      case 'ak-stage-authenticator-validate':
        _user = challenge['pending_user'] as String? ?? _user;
        final classes = [
          for (final d in (challenge['device_challenges'] as List?) ?? [])
            (d as Map<String, dynamic>)['device_class'],
        ];
        // TOTP and recovery codes are typed in; passkeys, push and the
        // rest need something the watch doesn't have.
        if (!classes.contains('totp') && !classes.contains('static')) {
          throw SsoException(SsoError.unsupportedStep, classes.join(','));
        }
        return SsoPrompt([SsoField.code], user: _user, retry: retry);
      case 'ak-stage-consent':
        return SsoConsent(_app);
      case 'ak-stage-user-login':
        // "Stay signed in?": irrelevant, the watch keeps no Authentik session.
        return await _handle(
          await _post({'component': component, 'remember_me': false}),
        );
      case 'xak-flow-redirect':
        final to = _executor.resolve(challenge['to'] as String);
        final (page, back) = await _follow(to);
        if (back != null) {
          redirect = back;
          return null;
        }
        if (page != null && matches(page.url)) return await _enter(page.url);
        throw SsoException(SsoError.unsupportedStep, page?.url.path);
      case 'ak-stage-access-denied':
        throw SsoException(
          SsoError.accessDenied,
          challenge['error_message'] as String?,
        );
      default:
        throw SsoException(SsoError.unsupportedStep, component);
    }
  }
}
