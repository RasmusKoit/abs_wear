import 'dart:convert';
import 'dart:io';

import 'package:abs_wear/login/view/login_page.dart';
import 'package:flutter/material.dart';
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
  late Map<String, http.Response Function()> routes;
  late http.Client client;

  setUp(() {
    root = Directory.systemTemp.createTempSync('abs_login_test');
    PathProviderPlatform.instance = _FakePathProvider(root.path);
    requests = [];
    bodies = [];
    routes = {};
    client = MockClient((request) async {
      final key = '${request.method} ${request.url.path}';
      requests.add(key);
      bodies.add(request.body);
      return routes[key]?.call() ?? http.Response('', 404);
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
      await tester.enterText(find.byType(TextFormField).at(1), 'alice ');
      await tester.enterText(find.byType(TextFormField).at(2), 'pw');
      await tester.tap(find.text('Login'));
      await tester.pumpAndSettle();
    }, () => client);

    expect(jsonDecode(bodies.first), containsPair('username', 'alice'));
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
      final login = tester.widget<ElevatedButton>(
        find.widgetWithText(ElevatedButton, 'Login'),
      );
      expect(login.onPressed, isNotNull);
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
}
