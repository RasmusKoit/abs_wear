import 'dart:async';
import 'dart:convert';

import 'package:abs_wear/login/data/sso/sso_http.dart';
import 'package:abs_wear/login/data/sso/sso_types.dart';
import 'package:http/http.dart' as http;

/// Pocket ID's "sign in with another device". Pocket ID only takes passkeys,
/// which the watch can't use, so the watch shows a code that the user
/// approves on a device already signed in to Pocket ID. Then the authorize
/// interaction is finished through the JSON API Pocket ID's own pages use.
class PocketIdAdapter implements IdpAdapter {
  PocketIdAdapter(IdpContext context)
    : _http = context.http,
      _follow = context.follow;

  /// The adapter for [page] if it is Pocket ID's authorize page.
  static IdpAdapter? forPage(SsoPage page, IdpContext context) =>
      matches(page) ? PocketIdAdapter(context) : null;

  final SsoHttp _http;
  final FollowRedirects _follow;

  @override
  String get name => 'Pocket ID';

  /// The authorize page: the API is on the same server.
  late Uri _page;
  late String _interaction;
  String _app = 'Audiobookshelf';

  /// The device login request being waited on, or null at consent.
  String? _request;
  late SsoWait _wait;

  @override
  Uri? redirect;

  /// Pocket ID waits up to 25 s for a decision before answering "pending".
  static const _exchangeWait = Duration(seconds: 40);

  /// Pocket ID shows an authorize request at `/interaction?interaction=<id>`
  /// and its pages load their icon from its `/api/application-images/`.
  static bool matches(SsoPage page) =>
      page.url.path == '/interaction' &&
      (page.url.queryParameters['interaction'] ?? '').isNotEmpty &&
      page.body.contains('/api/application-images/');

  @override
  Future<SsoStep> begin(SsoPage page) async {
    _page = page.url;
    _interaction = page.url.queryParameters['interaction']!;
    final interaction = _json(
      await _http.send('GET', _api(['oidc', 'interactions', _interaction])),
    );
    _app = _clientName(interaction) ?? _app;
    if (interaction['currentStep'] != 'authenticate') {
      throw SsoException(
        SsoError.unsupportedStep,
        interaction['currentStep'] as String?,
      );
    }
    final created = _json(
      await _http.send('POST', _api(['device-login', 'requests'])),
    );
    _request = created['id'] as String;
    final interval = created['interval'] as int? ?? 3;
    // The code to approve at /device on a signed-in device.
    return _wait = SsoWait(
      code: created['userCode'] as String,
      url: Uri.tryParse(created['verificationUri'] as String? ?? ''),
      poll: Duration(seconds: interval.clamp(1, 30)),
    );
  }

  @override
  Future<SsoStep?> submit(Map<SsoField, String> answer) async {
    final request = _request;
    if (request == null) return await _complete('consent');
    final http.Response response;
    try {
      response = await _http.send(
        'POST',
        _api(['device-login', 'requests', request, 'exchange']),
        wait: _exchangeWait,
      );
    } on TimeoutException {
      return _wait;
    }
    switch (response.statusCode) {
      case 200:
        // Signed in, as if with a login code.
        _request = null;
        return await _complete('authenticate');
      case 202 || 408 || 425 || 429 || 502 || 503 || 504:
        // Not decided yet, or a hiccup Pocket ID's own page also retries.
        return _wait;
      case 403:
        throw SsoException(SsoError.accessDenied, _error(response));
      case 401:
        throw const SsoException(SsoError.failed, 'device login expired');
      default:
        throw SsoException(SsoError.failed, _error(response));
    }
  }

  /// Completes the interaction's [step]. Null once Pocket ID sends the user
  /// back to the server ([redirect] set).
  Future<SsoStep?> _complete(String step) async {
    final response = await _http.send(
      'POST',
      _api(['oidc', 'interactions', _interaction, 'complete']),
      // No scopes: all requested scopes are approved.
      body: {'step': step},
    );
    if (response.statusCode == 403) {
      throw SsoException(SsoError.accessDenied, _error(response));
    }
    final result = _json(response);
    if (result['redirectUrl'] case final String to) {
      final (page, back) = await _follow(_page.resolve(to));
      if (back != null) {
        redirect = back;
        return null;
      }
      // Refusals (e.g. the user isn't in an allowed group) end here.
      if (page != null && page.url.path == '/interaction/error') {
        throw SsoException(
          SsoError.accessDenied,
          page.url.queryParameters['error'],
        );
      }
      throw SsoException(SsoError.failed, 'stopped at ${page?.url.path}');
    }
    final interaction = result['interaction'] as Map<String, dynamic>?;
    final next = interaction?['currentStep'] as String?;
    _app = _clientName(interaction) ?? _app;
    switch (next) {
      case 'consent':
        return SsoConsent(_app);
      case 'select_account':
        // The watch has only the account it just signed in with.
        return await _complete(next!);
      default:
        // "reauthenticate" needs a passkey.
        throw SsoException(SsoError.unsupportedStep, next);
    }
  }

  Uri _api(List<String> path) =>
      _page.resolveUri(Uri(pathSegments: ['', 'api', ...path]));

  static String? _clientName(Map<String, dynamic>? interaction) =>
      (interaction?['client'] as Map<String, dynamic>?)?['name'] as String?;

  /// The JSON object in a successful [response].
  static Map<String, dynamic> _json(http.Response response) {
    if (response.statusCode != 200 && response.statusCode != 201) {
      throw SsoException(SsoError.failed, _error(response));
    }
    try {
      return jsonDecode(response.body) as Map<String, dynamic>;
    } on FormatException {
      throw const SsoException(SsoError.failed, 'pocket id: not JSON');
    }
  }

  /// Pocket ID's error message in [response], else its status.
  static String _error(http.Response response) {
    try {
      final body = jsonDecode(response.body) as Map<String, dynamic>;
      if (body['error'] case final String error) return error;
    } on Object {
      // Not JSON.
    }
    return 'pocket id ${response.statusCode}';
  }
}
