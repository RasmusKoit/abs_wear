import 'dart:async';
import 'dart:convert';

import 'package:abs_wear/library/data/library_api.dart';
import 'package:abs_wear/login/data/auth_session.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _server = 'http://abs.test';

void main() {
  final auth = AuthSession.instance;
  late List<http.Request> requests;

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    requests = [];
    auth.clear();
  });

  tearDown(auth.clear);

  http.Response ok(Object body) => http.Response(jsonEncode(body), 200);

  http.Response refreshed(String access, String refresh) => ok({
    'user': {'accessToken': access, 'refreshToken': refresh},
  });

  /// Answers /auth/refresh with [refresh], and the API with 200 only for
  /// [valid].
  http.Client server({
    required FutureOr<http.Response> Function() refresh,
    String valid = 'acc2',
  }) => MockClient((request) async {
    requests.add(request);
    if (request.url.path == '/auth/refresh') return await refresh();
    return request.headers['Authorization'] == 'Bearer $valid'
        ? ok({'libraries': <Object>[]})
        : http.Response('', 401);
  });

  List<String> paths() => [for (final r in requests) r.url.path];

  group('LoginTokens.fromLogin', () {
    test('uses the access and refresh tokens', () {
      final tokens = LoginTokens.fromLogin(const {
        'user': {'accessToken': 'acc', 'refreshToken': 'ref', 'token': 'old'},
      });
      expect(tokens.access, 'acc');
      expect(tokens.refresh, 'ref');
    });

    test('falls back to the legacy token on older servers', () {
      final tokens = LoginTokens.fromLogin(const {
        'user': {'token': 'old'},
      });
      expect(tokens.access, 'old');
      expect(tokens.refresh, isNull);
    });

    test('prefers the legacy token to an access token it cannot refresh', () {
      final tokens = LoginTokens.fromLogin(const {
        'user': {'accessToken': 'acc', 'refreshToken': null, 'token': 'old'},
      });
      expect(tokens.access, 'old');
    });

    test('an access token alone is still used', () {
      final tokens = LoginTokens.fromLogin(const {
        'user': {'accessToken': 'acc'},
      });
      expect(tokens.access, 'acc');
      expect(tokens.refresh, isNull);
    });

    test('throws without a usable token', () {
      for (final data in const <Map<String, dynamic>>[
        {},
        {'user': <String, dynamic>{}},
        {
          'user': {'token': '', 'accessToken': null},
        },
      ]) {
        expect(
          () => LoginTokens.fromLogin(data),
          throwsA(isA<MissingTokenException>()),
        );
      }
    });
  });

  group('refresh', () {
    test('a 401 refreshes once and retries with the new token', () async {
      auth.start(_server, 'acc1', 'ref1');

      final response = await http.runWithClient(
        () => apiGet('$_server/api/libraries', 'acc1'),
        () => server(refresh: () => refreshed('acc2', 'ref2')),
      );

      expect(response.statusCode, 200);
      expect(paths(), ['/api/libraries', '/auth/refresh', '/api/libraries']);
      expect(requests[1].method, 'POST');
      expect(requests[1].headers['x-refresh-token'], 'ref1');
      expect(requests[2].headers['Authorization'], 'Bearer acc2');
      expect(auth.accessToken, 'acc2');
      expect(auth.refreshToken, 'ref2');
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString('token'), 'acc2');
      expect(prefs.getString('refreshToken'), 'ref2');
    });

    test('concurrent 401s share one refresh', () async {
      auth.start(_server, 'acc1', 'ref1');
      final answer = Completer<http.Response>();

      final responses = await http.runWithClient(() async {
        final all = Future.wait([
          for (var i = 0; i < 3; i++) apiGet('$_server/api/x$i', 'acc1'),
        ]);
        while (!paths().contains('/auth/refresh')) {
          await Future<void>.delayed(Duration.zero);
        }
        answer.complete(refreshed('acc2', 'ref2'));
        return await all;
      }, () => server(refresh: () => answer.future));

      expect(responses.map((r) => r.statusCode), [200, 200, 200]);
      expect(paths().where((p) => p == '/auth/refresh'), hasLength(1));
    });

    test('a caller holding the old token sends the new one', () async {
      auth.start(_server, 'acc1', 'ref1');
      final client = server(refresh: () => refreshed('acc2', 'ref2'));
      await http.runWithClient(
        () => apiGet('$_server/api/a', 'acc1'),
        () => client,
      );
      requests.clear();

      final response = await http.runWithClient(
        () => apiGet('$_server/api/b', 'acc1'),
        () => client,
      );

      expect(response.statusCode, 200);
      expect(paths(), ['/api/b']);
      expect(requests.single.headers['Authorization'], 'Bearer acc2');
    });

    test('a rejected refresh token ends in the 401, once', () async {
      auth.start(_server, 'acc1', 'ref1');
      final client = server(refresh: () => http.Response('', 401));

      final first = await http
          .runWithClient(() => getJson('$_server/api/a', 'acc1'), () => client)
          .then<Object?>((v) => v, onError: (Object e) => e);
      final second = await http.runWithClient(
        () => apiGet('$_server/api/b', 'acc1'),
        () => client,
      );

      expect(first, isA<ApiException>());
      expect((first! as ApiException).result, LibraryResult.sessionExpired);
      expect(second.statusCode, 401);
      expect(paths().where((p) => p == '/auth/refresh'), hasLength(1));
    });

    test('a refresh the server could not answer is not a logout', () async {
      auth.start(_server, 'acc1', 'ref1');

      final call = http.runWithClient(
        () => apiGet('$_server/api/a', 'acc1'),
        () => server(refresh: () => http.Response('', 429)),
      );

      await expectLater(call, throwsA(isA<TokenRefreshException>()));
      expect(auth.refreshToken, 'ref1');
    });

    test('a legacy token is never refreshed', () async {
      auth.start(_server, 'legacy', null);

      final response = await http.runWithClient(
        () => apiGet('$_server/api/a', 'legacy'),
        () => server(refresh: () => refreshed('acc2', 'ref2')),
      );

      expect(response.statusCode, 401);
      expect(paths(), ['/api/a']);
    });

    test('a refresh finishing after logout saves nothing', () async {
      auth.start(_server, 'acc1', 'ref1');
      final answer = Completer<http.Response>();

      final response = await http.runWithClient(() async {
        final call = apiGet('$_server/api/a', 'acc1');
        while (!paths().contains('/auth/refresh')) {
          await Future<void>.delayed(Duration.zero);
        }
        auth.clear();
        answer.complete(refreshed('acc2', 'ref2'));
        return await call;
      }, () => server(refresh: () => answer.future));

      expect(response.statusCode, 401);
      expect(auth.accessToken, isEmpty);
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString('token'), isNull);
      expect(prefs.getString('refreshToken'), isNull);
    });
  });

  group('expiry', () {
    final now = DateTime(2026, 11, 13, 12);

    String jwt(Map<String, Object> payload) {
      String part(Object json) =>
          base64Url.encode(utf8.encode(jsonEncode(json))).replaceAll('=', '');
      return '${part({'alg': 'HS256'})}.${part(payload)}.sig';
    }

    final expiry = now.add(const Duration(hours: 1));
    final acc1 = jwt({'exp': expiry.millisecondsSinceEpoch ~/ 1000});

    setUp(() => auth.clock = () => now);
    tearDown(() => auth.clock = DateTime.now);

    test('reads exp from a JWT, nothing from a legacy token', () {
      expect(AuthSession.expiryOf(acc1), expiry);
      expect(AuthSession.expiryOf(jwt({'userId': 'u'})), isNull);
      expect(AuthSession.expiryOf('not-a-jwt'), isNull);
    });

    test('renewal is due the margin before expiry', () {
      auth.start(_server, acc1, 'ref1');
      const margin = Duration(minutes: 2);

      expect(auth.renewIn(acc1, margin: margin), const Duration(minutes: 58));
      auth.clock = () => expiry;
      expect(auth.renewIn(acc1, margin: margin), Duration.zero);
      auth.start(_server, acc1, null);
      expect(auth.renewIn(acc1, margin: margin), isNull);
    });

    test('freshToken refreshes only close to expiry', () async {
      auth.start(_server, acc1, 'ref1');
      final client = server(refresh: () => refreshed('acc2', 'ref2'));
      const margin = Duration(minutes: 2);

      final early = await http.runWithClient(
        () => auth.freshToken(acc1, margin: margin),
        () => client,
      );
      auth.clock = () => expiry.subtract(const Duration(minutes: 1));
      final late = await http.runWithClient(
        () => auth.freshToken(acc1, margin: margin),
        () => client,
      );

      expect(early, acc1);
      expect(late, 'acc2');
      expect(paths(), ['/auth/refresh']);
      expect(auth.isStale(acc1), isTrue, reason: 'replaced');
    });
  });
}
