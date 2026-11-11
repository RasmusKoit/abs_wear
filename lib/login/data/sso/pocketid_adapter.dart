import 'dart:async';
import 'dart:convert';
import 'dart:io' show HttpDate, HttpException;

import 'package:abs_wear/login/data/sso/sso_http.dart';
import 'package:abs_wear/login/data/sso/sso_types.dart';
import 'package:http/http.dart' as http;

/// Pocket ID's "sign in with another device". Pocket ID only takes passkeys,
/// which the watch can't use, so the watch shows a code that the user
/// approves on a device already signed in to Pocket ID. Then the authorize
/// interaction is finished through the JSON API Pocket ID's own pages use.
class PocketIdAdapter implements IdpAdapter {
  PocketIdAdapter(
    IdpContext context, {
    DateTime Function() now = DateTime.now,
    Duration exchangeWait = const Duration(seconds: 40),
  }) : _http = context.http,
       _follow = context.follow,
       _now = now,
       _exchangeWait = exchangeWait;

  /// The adapter for [page] if it is Pocket ID's authorize page.
  static IdpAdapter? forPage(SsoPage page, IdpContext context) =>
      matches(page) ? PocketIdAdapter(context) : null;

  final SsoHttp _http;
  final FollowRedirects _follow;
  final DateTime Function() _now;

  /// How long one status check may take. Pocket ID holds it open up to 25 s
  /// while nothing is decided.
  final Duration _exchangeWait;

  @override
  String get name => 'Pocket ID';

  /// The authorize page: the API is on the same server.
  late Uri _page;
  late String _interaction;
  String _app = 'Audiobookshelf';

  /// The device login request being waited on, or null at consent.
  String? _request;
  late SsoWait _wait;

  /// When the request has surely expired, by the watch's clock: polling
  /// stops then even if Pocket ID can't be reached to say so.
  late DateTime _deadline;

  @override
  Uri? redirect;

  /// How long a request lasts when Pocket ID doesn't say (its default).
  static const _requestLifetime = Duration(minutes: 5);

  /// Extra time past the expiry, for a decision taken at the last moment.
  static const _deadlineMargin = Duration(seconds: 30);

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
    final step = interaction['currentStep'];
    if (step != 'authenticate') {
      throw SsoException(
        SsoError.unsupportedStep,
        step is String ? step : null,
      );
    }
    final response = await _http.send(
      'POST',
      _api(['device-login', 'requests']),
    );
    final created = _json(response);
    if (created case {
      'id': final String id,
      'userCode': final String code,
    } when id.isNotEmpty && code.isNotEmpty) {
      _request = id;
      _deadline = _now().add(_lifetime(response, created) + _deadlineMargin);
      final interval = switch (created['interval']) {
        final num n => n.toInt(),
        _ => 3,
      };
      final verify = created['verificationUri'];
      // The code to approve at /device on a signed-in device.
      return _wait = SsoWait(
        code: code,
        url: verify is String ? Uri.tryParse(verify) : null,
        poll: Duration(seconds: interval.clamp(1, 30)),
      );
    }
    throw const SsoException(SsoError.failed, 'pocket id: unexpected response');
  }

  /// How long the created request lasts: its `expiresAt` measured against
  /// the server's own clock (its Date header), so a watch whose clock is off
  /// doesn't give up early or late.
  Duration _lifetime(http.Response response, Map<String, dynamic> created) {
    final expires = switch (created['expiresAt']) {
      final String at => DateTime.tryParse(at),
      _ => null,
    };
    if (expires == null) return _requestLifetime;
    DateTime? sent;
    try {
      final date = response.headers['date'];
      if (date != null) sent = HttpDate.parse(date);
    } on FormatException {
      // No usable Date header: use the watch's clock.
    } on HttpException {
      // Likewise.
    }
    final left = expires.difference(sent ?? _now());
    if (left.isNegative) return Duration.zero;
    return left > const Duration(minutes: 30) ? _requestLifetime : left;
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
      return _keepWaiting();
    } on http.ClientException {
      // The network dropped for a moment (e.g. a SocketException): try
      // again on the next poll, until the request has surely expired.
      return _keepWaiting();
    }
    switch (response.statusCode) {
      case 200:
        // Signed in, as if with a login code.
        _request = null;
        return await _complete('authenticate');
      case 202 || 408 || 425 || 429 || 502 || 503 || 504:
        // Not decided yet, or a hiccup Pocket ID's own page also retries.
        return _keepWaiting();
      case 403:
        throw SsoException(SsoError.accessDenied, _error(response));
      case 401:
        throw const SsoException(SsoError.failed, 'device login expired');
      default:
        throw SsoException(SsoError.failed, _error(response));
    }
  }

  /// The same code again, unless the request has expired by now (Pocket ID
  /// may be unreachable and never say so).
  SsoWait _keepWaiting() {
    if (_now().isAfter(_deadline)) {
      throw const SsoException(SsoError.failed, 'device login expired');
    }
    return _wait;
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
      // Errors Pocket ID can't send back to the server end here: refusals
      // (the user isn't in an allowed group, or is disabled) and failures
      // (e.g. the interaction was already used or has expired).
      if (page != null && page.url.path == '/interaction/error') {
        final error = page.url.queryParameters['error'];
        final text = error?.toLowerCase() ?? '';
        final refused =
            text.contains('not allowed to access') || text.contains('disabled');
        throw SsoException(
          refused ? SsoError.accessDenied : SsoError.failed,
          error,
        );
      }
      throw SsoException(SsoError.failed, 'stopped at ${page?.url.path}');
    }
    final interaction = switch (result['interaction']) {
      final Map<String, dynamic> i => i,
      _ => null,
    };
    final next = switch (interaction?['currentStep']) {
      final String step => step,
      _ => null,
    };
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
      switch (interaction?['client']) {
        {'name': final String name} => name,
        _ => null,
      };

  /// The JSON object in a successful [response].
  static Map<String, dynamic> _json(http.Response response) {
    if (response.statusCode != 200 && response.statusCode != 201) {
      throw SsoException(SsoError.failed, _error(response));
    }
    final Object? body;
    try {
      body = jsonDecode(response.body);
    } on FormatException {
      throw const SsoException(SsoError.failed, 'pocket id: not JSON');
    }
    if (body is Map<String, dynamic>) return body;
    throw const SsoException(SsoError.failed, 'pocket id: unexpected response');
  }

  /// Pocket ID's error message in [response], else its status.
  static String _error(http.Response response) {
    try {
      if (jsonDecode(response.body) case {'error': final String error}) {
        return error;
      }
    } on FormatException {
      // Not JSON.
    }
    return 'pocket id ${response.statusCode}';
  }
}
