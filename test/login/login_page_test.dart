import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:abs_wear/login/data/auth_session.dart';
import 'package:abs_wear/login/view/login_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:plugin_platform_interface/plugin_platform_interface.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../helpers/helpers.dart';

class _FakePathProvider extends PathProviderPlatform
    with MockPlatformInterfaceMixin {
  _FakePathProvider(this.path);
  final String path;

  // Apart, as on a device: logout empties the documents directory.
  @override
  Future<String?> getApplicationDocumentsPath() async => '$path/docs';

  @override
  Future<String?> getApplicationSupportPath() async => '$path/support';
}

const _server = 'http://abs.test';

void main() {
  late Directory root;
  late List<String> requests;
  late List<String> bodies;
  late List<http.Request> sent;
  late Map<String, FutureOr<http.Response> Function()> routes;
  late http.Client client;

  setUp(() {
    root = Directory.systemTemp.createTempSync('abs_login_test');
    PathProviderPlatform.instance = _FakePathProvider(root.path);
    requests = [];
    bodies = [];
    sent = [];
    routes = {};
    client = MockClient((request) async {
      final key = '${request.method} ${request.url.path}';
      requests.add(key);
      sent.add(request);
      bodies.add(request.body);
      return await routes[key]?.call() ?? http.Response('', 404);
    });
  });

  tearDown(() => root.deleteSync(recursive: true));

  http.Response ok(Object body) => http.Response(jsonEncode(body), 200);

  LoginPageState state(WidgetTester tester) =>
      tester.state<LoginPageState>(find.byType(LoginPage));

  testWidgets('a username with spaces logs in as the trimmed name', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({});
    routes['GET /status'] = () => ok({
      'authMethods': ['local'],
    });
    routes['POST /login'] = () => ok({
      'user': {'token': 'tok'},
      'userDefaultLibraryId': 'lib1',
    });
    routes['GET /api/libraries'] = () => ok({
      'libraries': [
        {'id': 'lib1', 'mediaType': 'book'},
      ],
    });
    await http.runWithClient(() async {
      await tester.pumpApp(const LoginPage());
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextFormField).at(0), _server);
      await tester.tap(find.text('Next'));
      await tester.pumpAndSettle();
      // Password-only server: the username, then the password.
      await tester.enterText(find.byType(TextFormField).at(0), 'alice ');
      await tester.tap(find.text('Next'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextFormField).at(0), 'pw');
      await tester.tap(find.text('Login'));
      await tester.pumpAndSettle();
    }, () => client);

    expect(
      jsonDecode(bodies[requests.indexOf('POST /login')]),
      containsPair('username', 'alice'),
    );
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getString('username'), 'alice');
    // The identity used from now on (library, offline progress) matches.
    expect(state(tester).usernameController.text, 'alice');
    expect(find.text('Hello alice'), findsOneWidget);
  });

  group('logout', () {
    final updatedAt = DateTime.now().millisecondsSinceEpoch - 60000;
    late Directory progressDir;

    File progressFile(
      String itemId, {
      required bool pending,
      int listenedMs = 0,
    }) {
      final file = File('${progressDir.path}/$itemId.json')
        ..parent.createSync(recursive: true)
        ..writeAsStringSync(
          jsonEncode({
            'server': _server,
            'user': 'alice',
            'itemId': itemId,
            'duration': 600,
            'currentTime': 50,
            'listenedMs': listenedMs,
            'updatedAt': updatedAt,
            'pending': pending,
          }),
        );
      return file;
    }

    setUp(() {
      // The login form scrolls with the crown once the logout shows it.
      fakeCrown();
      // Present on a device; logout lists it to delete downloads.
      Directory('${root.path}/docs').createSync();
      progressDir = Directory('${root.path}/support/offline_progress');
      SharedPreferences.setMockInitialValues({
        'serverUrl': _server,
        'username': 'alice',
        'token': 'tok',
        'defaultLibraryId': 'lib1',
      });
    });

    /// What the confirm button runs, but in the real zone: the push queue
    /// (AudioPlayerController._pushing) is static, and a push started in an
    /// earlier test's fake-async zone leaves a future there whose callbacks
    /// never run in this test's zone, so the push would hang until its
    /// timeout. Real zones are shared, so order between tests can't matter.
    Future<void> logOut(WidgetTester tester) async {
      await tester.pumpApp(const LoginPage());
      await tester.pumpAndSettle();
      expect(find.text('Hello alice'), findsOneWidget);
      await tester.runAsync(
        () => http.runWithClient(
          () => state(tester).logout(deleteDownloads: true),
          () => client,
        ),
      );
      await tester.pumpAndSettle();
    }

    ElevatedButton loginButton(WidgetTester tester) =>
        tester.widget<ElevatedButton>(find.byType(ElevatedButton));

    /// Waits (in real time) for the revoke, which logout doesn't await, to
    /// drop the pending logout.
    Future<void> revoked(WidgetTester tester) => tester.runAsync(() async {
      final prefs = await SharedPreferences.getInstance();
      while (prefs.getStringList('pendingLogout') != null) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
    });

    testWidgets('sends offline progress before deleting it', (tester) async {
      final pending = progressFile('li_1', pending: true);
      final synced = progressFile('li_2', pending: false);
      final download = Directory('${root.path}/docs/li_2')
        ..createSync(recursive: true);
      routes['GET /api/me/progress/li_1'] = () => http.Response('', 404);
      routes['PATCH /api/me/progress/li_1'] = () => ok({});
      routes['POST /logout'] = () => ok({});

      await logOut(tester);

      expect(requests, [
        'GET /api/me/progress/li_1',
        'PATCH /api/me/progress/li_1',
        'POST /logout',
      ]);
      expect(jsonDecode(bodies[1]), containsPair('currentTime', 50));
      expect(pending.existsSync(), isFalse);
      expect(synced.existsSync(), isFalse);
      expect(download.existsSync(), isFalse);
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString('token'), isNull);
      // The login form is usable again once the logout finished.
      expect(find.text('Next'), findsOneWidget);
      expect(loginButton(tester).onPressed, isNotNull);
      await revoked(tester);
    });

    testWidgets('deletes downloads while the push still waits', (tester) async {
      final pending = progressFile('li_1', pending: true);
      final download = Directory('${root.path}/docs/li_2')
        ..createSync(recursive: true);
      final cache = Directory('${root.path}/support/json_cache')
        ..createSync(recursive: true);
      final answer = Completer<http.Response>();
      routes['GET /api/me/progress/li_1'] = () => answer.future;
      routes['POST /logout'] = () => ok({});
      await tester.pumpApp(const LoginPage());
      await tester.pumpAndSettle();

      late Future<void> loggedOut;
      await tester.runAsync(() async {
        loggedOut = http.runWithClient(
          () => state(tester).logout(deleteDownloads: true),
          () => client,
        );
        // Until the push waits for a server that doesn't answer.
        while (!requests.contains('GET /api/me/progress/li_1')) {
          await Future<void>.delayed(const Duration(milliseconds: 10));
        }
      });
      await tester.pump();

      expect(download.existsSync(), isFalse);
      expect(cache.existsSync(), isFalse);
      expect(pending.existsSync(), isTrue);
      expect(requests, isNot(contains('POST /logout')));
      // A new login waits for the rest of the cleanup.
      expect(loginButton(tester).onPressed, isNull);

      // Answered only now, so the test doesn't wait out the push's timeout.
      await tester.runAsync(() async {
        answer.complete(http.Response('', 503));
        await loggedOut;
      });
      await tester.pumpAndSettle();
      expect(requests, contains('POST /logout'));
      expect(loginButton(tester).onPressed, isNotNull);
      await revoked(tester);
    });

    testWidgets('a logout cut short is finished on the next start', (
      tester,
    ) async {
      // Killed after the token was dropped, before the cleanup ended.
      SharedPreferences.setMockInitialValues({
        'serverUrl': _server,
        'username': 'alice',
        'pickedLibrary': 'lib1',
        'pendingLogout': <String>[_server, 'tok'],
      });
      final pending = progressFile('li_1', pending: true);
      final synced = progressFile('li_2', pending: false);
      final download = Directory('${root.path}/docs/li_2')
        ..createSync(recursive: true);
      routes['POST /logout'] = () => ok({});

      await http.runWithClient(() async {
        await tester.pumpApp(const LoginPage());
        await tester.pumpAndSettle();
      }, () => client);

      expect(download.existsSync(), isFalse);
      expect(synced.existsSync(), isFalse);
      // Kept for alice's next login to send, as after a finished logout.
      expect(pending.existsSync(), isTrue);
      expect(requests, ['POST /logout']);
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getStringList('pendingLogout'), isNull);
      expect(prefs.getString('pickedLibrary'), isNull);
      expect(find.text('Next'), findsOneWidget);
    });

    testWidgets('a logout cut short before dropping its token is finished', (
      tester,
    ) async {
      // Killed after the marker was written, before the token was removed:
      // the saved token is the one being logged out, not a newer login.
      SharedPreferences.setMockInitialValues({
        'serverUrl': _server,
        'username': 'alice',
        'token': 'tok',
        'defaultLibraryId': 'lib1',
        'pendingLogout': <String>[_server, 'tok'],
      });
      final download = Directory('${root.path}/docs/li_2')
        ..createSync(recursive: true);
      routes['POST /logout'] = () => ok({});

      await http.runWithClient(() async {
        await tester.pumpApp(const LoginPage());
        await tester.pumpAndSettle();
      }, () => client);

      expect(download.existsSync(), isFalse);
      expect(requests, ['POST /logout']);
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString('token'), isNull);
      expect(prefs.getStringList('pendingLogout'), isNull);
      expect(find.text('Next'), findsOneWidget);
    });

    testWidgets("a cut short logout keeps a newer login's downloads", (
      tester,
    ) async {
      // Killed while revoking, after bob had logged in.
      SharedPreferences.setMockInitialValues({
        'serverUrl': _server,
        'username': 'bob',
        'token': 'tok2',
        'defaultLibraryId': 'lib1',
        'pendingLogout': <String>[_server, 'tok'],
      });
      final download = Directory('${root.path}/docs/li_2')
        ..createSync(recursive: true);
      routes['POST /logout'] = () => ok({});

      await http.runWithClient(() async {
        await tester.pumpApp(const LoginPage());
        await tester.pumpAndSettle();
      }, () => client);

      expect(download.existsSync(), isTrue);
      // Bob's restored session also warms up connections.
      expect(
        requests,
        unorderedEquals([
          'POST /logout',
          'GET /ping',
          'GET /ping',
          'GET /ping',
        ]),
      );
      expect(bodies[requests.indexOf('POST /logout')], '');
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getStringList('pendingLogout'), isNull);
      expect(find.text('Hello bob'), findsOneWidget);
    });

    testWidgets('keeps listening time the push could not report', (
      tester,
    ) async {
      // Played offline for 2 min: the push sends the position, but the
      // listening time only reaches the server through a playback session.
      final listened = progressFile('li_1', pending: true, listenedMs: 120000);
      routes['GET /api/me/progress/li_1'] = () => http.Response('', 404);
      routes['PATCH /api/me/progress/li_1'] = () => ok({});
      routes['POST /logout'] = () => ok({});

      await logOut(tester);

      expect(requests, contains('PATCH /api/me/progress/li_1'));
      // Kept for alice's next online play of the book to report.
      expect(listened.existsSync(), isTrue);
      final json =
          jsonDecode(listened.readAsStringSync()) as Map<String, dynamic>;
      expect(json['pending'], isFalse);
      expect(json['listenedMs'], 120000);
    });

    testWidgets('keeps offline progress the server could not take', (
      tester,
    ) async {
      final pending = progressFile('li_1', pending: true);
      routes['GET /api/me/progress/li_1'] = () => http.Response('', 503);
      routes['POST /logout'] = () => ok({});

      await logOut(tester);

      expect(requests, contains('POST /logout'));
      expect(requests, isNot(contains('PATCH /api/me/progress/li_1')));
      // Still pending, for alice's next login to send.
      expect(pending.existsSync(), isTrue);
      final json =
          jsonDecode(pending.readAsStringSync()) as Map<String, dynamic>;
      expect(json['pending'], isTrue);
    });
  });

  group('warm-up', () {
    testWidgets('a restored session pings the server with its token', (
      tester,
    ) async {
      SharedPreferences.setMockInitialValues({
        'serverUrl': _server,
        'username': 'alice',
        'token': 'tok',
        'defaultLibraryId': 'lib1',
      });
      final pings = <http.Request>[];
      final client = MockClient((request) async {
        if (request.url.path == '/ping') pings.add(request);
        return http.Response('', 404);
      });

      await http.runWithClient(() async {
        await tester.pumpApp(const LoginPage());
        await tester.pumpAndSettle();
      }, () => client);

      expect(find.text('Hello alice'), findsOneWidget);
      expect(pings, hasLength(3));
      for (final ping in pings) {
        expect(ping.method, 'GET');
        expect(ping.url.toString(), '$_server/ping');
        expect(ping.headers['Authorization'], 'Bearer tok');
      }
    });
  });

  group('tokens', () {
    const toast = MethodChannel('toast');
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    late List<String> toasts;

    setUp(() {
      toasts = [];
      messenger.setMockMethodCallHandler(toast, (call) async {
        toasts.add((call.arguments as Map)['message'] as String);
        return null;
      });
      routes['GET /status'] = () => ok({
        'authMethods': ['local'],
      });
      routes['GET /api/libraries'] = () => ok({
        'libraries': [
          {'id': 'lib1', 'mediaType': 'book'},
        ],
      });
    });

    tearDown(() {
      messenger.setMockMethodCallHandler(toast, null);
      AuthSession.instance.clear();
    });

    Future<void> logIn(WidgetTester tester) => http.runWithClient(() async {
      await tester.pumpApp(const LoginPage());
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextFormField).at(0), _server);
      await tester.tap(find.text('Next'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextFormField).at(0), 'alice');
      await tester.tap(find.text('Next'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextFormField).at(0), 'pw');
      await tester.tap(find.text('Login'));
      await tester.pumpAndSettle();
    }, () => client);

    testWidgets('login asks for refresh tokens and keeps both', (tester) async {
      SharedPreferences.setMockInitialValues({});
      routes['POST /login'] = () => ok({
        'user': {'accessToken': 'acc', 'refreshToken': 'ref', 'token': 'old'},
      });

      await logIn(tester);

      final login = sent.firstWhere((r) => r.url.path == '/login');
      expect(login.headers['x-return-tokens'], 'true');
      final libraries = sent.firstWhere((r) => r.url.path == '/api/libraries');
      expect(libraries.headers['Authorization'], 'Bearer acc');
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString('token'), 'acc');
      expect(prefs.getString('refreshToken'), 'ref');
      expect(AuthSession.instance.refreshToken, 'ref');
      expect(find.text('Hello alice'), findsOneWidget);
    });

    testWidgets('a login without a usable token says so', (tester) async {
      SharedPreferences.setMockInitialValues({});
      routes['POST /login'] = () => ok({
        'user': {'username': 'alice'},
      });

      await logIn(tester);

      expect(toasts, ['The server sent no usable login token.']);
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString('token'), isNull);
      expect(find.text('Hello alice'), findsNothing);
    });

    testWidgets('an install with only a legacy token still restores', (
      tester,
    ) async {
      SharedPreferences.setMockInitialValues({
        'serverUrl': _server,
        'username': 'alice',
        'token': 'legacy',
        'defaultLibraryId': 'lib1',
      });

      await http.runWithClient(() async {
        await tester.pumpApp(const LoginPage());
        await tester.pumpAndSettle();
      }, () => client);

      expect(find.text('Hello alice'), findsOneWidget);
      expect(AuthSession.instance.accessToken, 'legacy');
      expect(AuthSession.instance.refreshToken, isNull);
    });

    testWidgets('logout revokes the refresh token', (tester) async {
      fakeCrown();
      Directory('${root.path}/docs').createSync();
      SharedPreferences.setMockInitialValues({
        'serverUrl': _server,
        'username': 'alice',
        'token': 'acc',
        'refreshToken': 'ref',
        'defaultLibraryId': 'lib1',
      });
      routes['POST /logout'] = () => ok({});
      await http.runWithClient(() async {
        await tester.pumpApp(const LoginPage());
        await tester.pumpAndSettle();
      }, () => client);

      await tester.runAsync(() async {
        await http.runWithClient(
          () => state(tester).logout(deleteDownloads: true),
          () => client,
        );
        while (!requests.contains('POST /logout')) {
          await Future<void>.delayed(const Duration(milliseconds: 10));
        }
      });
      await tester.pumpAndSettle();

      final request = sent.firstWhere((r) => r.url.path == '/logout');
      expect(request.headers['x-refresh-token'], 'ref');
      expect(request.headers['Authorization'], 'Bearer acc');

      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString('token'), isNull);
      expect(prefs.getString('refreshToken'), isNull);
      expect(AuthSession.instance.accessToken, isEmpty);
    });
  });
}
