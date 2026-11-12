import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

/// A login response held no token the app can use.
class MissingTokenException implements Exception {
  const MissingTokenException();

  @override
  String toString() => 'MissingTokenException';
}

/// /auth/refresh failed for a reason other than a rejected token (e.g. 429).
class TokenRefreshException implements Exception {
  const TokenRefreshException(this.statusCode);
  final int statusCode;

  @override
  String toString() => 'TokenRefreshException($statusCode)';
}

/// The tokens of a login response.
@immutable
class LoginTokens {
  const LoginTokens(this.access, this.refresh);

  /// Reads a /login or SSO callback response; throws [MissingTokenException].
  factory LoginTokens.fromLogin(Map<String, dynamic> data) {
    final user = data['user'];
    if (user is! Map<String, dynamic>) throw const MissingTokenException();
    String? read(String key) {
      final value = user[key];
      return value is String && value.isNotEmpty ? value : null;
    }

    final access = read('accessToken');
    final refresh = read('refreshToken');
    if (access != null && refresh != null) return LoginTokens(access, refresh);
    // Deprecated: legacy token, only for servers without access tokens.
    final legacy = read('token');
    if (legacy != null) return LoginTokens(legacy, null);
    if (access != null) return LoginTokens(access, null);
    throw const MissingTokenException();
  }

  final String access;

  /// Null for a legacy token, which can't be refreshed.
  final String? refresh;
}

/// The logged-in session's tokens, shared so one refresh serves all requests.
class AuthSession {
  AuthSession._();

  static final instance = AuthSession._();

  /// Preference keys; `token` is also where older installs keep a legacy token.
  static const accessKey = 'token';
  static const refreshKey = 'refreshToken';

  String _serverUrl = '';
  String _access = '';
  String? _refresh;

  /// Access tokens replaced by a refresh, mapped to the current one on use.
  final Set<String> _replaced = {};

  /// The refresh in flight, shared by concurrent 401s.
  Future<String?>? _refreshing;

  /// Bumped on every login and logout, so a late refresh saves nothing.
  int _generation = 0;

  String get accessToken => _access;
  String? get refreshToken => _refresh;

  /// Starts using a session (after login or on app start).
  void start(String serverUrl, String access, String? refresh) {
    _generation++;
    _serverUrl = serverUrl;
    _access = access;
    _refresh = refresh;
    _replaced.clear();
    _refreshing = null;
  }

  /// Forgets the session (logout).
  void clear() => start('', '', null);

  /// The token to send in place of [token] (the new one if it was refreshed).
  String current(String token) => _replaced.contains(token) ? _access : token;

  /// A fresh access token after [failed] got a 401, or null to log in again.
  Future<String?> refreshAfter401(String failed) {
    if (_access.isEmpty) return Future.value();
    if (failed != _access) {
      return Future.value(_replaced.contains(failed) ? _access : null);
    }
    if (_refresh == null) return Future.value();
    final pending = _refreshing;
    if (pending != null) return pending;
    late final Future<String?> refreshing;
    refreshing = _refreshNow().whenComplete(() {
      if (identical(_refreshing, refreshing)) _refreshing = null;
    });
    return _refreshing = refreshing;
  }

  Future<String?> _refreshNow() async {
    final generation = _generation;
    final old = _access;
    final response = await http
        .post(
          Uri.parse('$_serverUrl/auth/refresh'),
          headers: {'x-refresh-token': _refresh!},
        )
        .timeout(const Duration(seconds: 20));
    if (generation != _generation) return null;
    if (const {400, 401, 403}.contains(response.statusCode)) {
      // Rejected for good: later 401s skip straight to "session expired".
      _refresh = null;
      return null;
    }
    if (response.statusCode != 200) {
      throw TokenRefreshException(response.statusCode);
    }
    final body = jsonDecode(response.body) as Map<String, dynamic>;
    final user = body['user'] as Map<String, dynamic>;
    final access = user['accessToken'];
    if (access is! String || access.isEmpty) return null;
    final refresh = user['refreshToken'];
    _replaced.add(old);
    _access = access;
    if (refresh is String && refresh.isNotEmpty) _refresh = refresh;
    final prefs = await SharedPreferences.getInstance();
    if (generation == _generation) {
      await prefs.setString(accessKey, _access);
      await prefs.setString(refreshKey, _refresh!);
    }
    return access;
  }

  /// Sends [request] with [token], and once more after a refresh on a 401.
  Future<R> send<R extends http.BaseResponse>(
    String token,
    Future<R> Function(String token) request,
  ) async {
    final sent = current(token);
    final response = await request(sent);
    if (response.statusCode != 401) return response;
    final fresh = await refreshAfter401(sent);
    if (fresh == null) return response;
    if (response is http.StreamedResponse) {
      await response.stream.listen(null).cancel();
    }
    return await request(fresh);
  }
}
