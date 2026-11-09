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

    File progressFile(String itemId, {required bool pending}) {
      final file = File('${progressDir.path}/$itemId.json')
        ..parent.createSync(recursive: true)
        ..writeAsStringSync(
          jsonEncode({
            'server': _server,
            'user': 'alice',
            'itemId': itemId,
            'duration': 600,
            'currentTime': 50,
            'listenedMs': 0,
            'updatedAt': updatedAt,
            'pending': pending,
          }),
        );
      return file;
    }

    setUp(() {
      progressDir = Directory('${root.path}/support/offline_progress');
      SharedPreferences.setMockInitialValues({
        'serverUrl': _server,
        'username': 'alice',
        'token': 'tok',
        'defaultLibraryId': 'lib1',
      });
    });

    Future<void> logOut(WidgetTester tester) => http.runWithClient(() async {
      await tester.pumpApp(const LoginPage());
      await tester.pumpAndSettle();
      expect(find.text('Hello alice'), findsOneWidget);
      await tester.tap(find.text('Logout'));
      await tester.pumpAndSettle();
      await tester.tap(find.byIcon(Icons.check_rounded));
      await tester.pumpAndSettle();
    }, () => client);

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
