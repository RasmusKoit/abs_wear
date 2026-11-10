import 'dart:io';

import 'package:abs_wear/login/view/login_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../helpers/helpers.dart';

void main() {
  late Directory root;

  setUp(() {
    root = Directory.systemTemp.createTempSync('abs_sso_test');
    PathProviderPlatform.instance = FakePathProvider(root.path);
    SharedPreferences.setMockInitialValues({});
  });

  tearDown(() => root.deleteSync(recursive: true));

  Future<void> startSso(WidgetTester tester) async {
    await tester.pumpApp(const LoginPage());
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextFormField).first, fakeAbsUrl);
    await tester.tap(find.text('Next'));
    await tester.pumpAndSettle();
    // The server offers both: choose SSO.
    await tester.ensureVisible(find.text('Login with SSO'));
    await tester.tap(find.text('Login with SSO'));
    await tester.pumpAndSettle();
  }

  Future<void> fill(WidgetTester tester, String label, String text) async {
    await tester.enterText(find.widgetWithText(TextFormField, label), text);
    await tester.ensureVisible(find.text('Continue'));
    await tester.tap(find.text('Continue'));
    await tester.pumpAndSettle();
  }

  testWidgets('logs in with SSO screen by screen', (tester) async {
    final servers = FakeServers();
    await http.runWithClient(() async {
      await startSso(tester);
      expect(find.byType(TextFormField), findsOneWidget);
      await fill(tester, 'Username', 'wear');
      // The account being logged in, then its password.
      expect(find.text('wear'), findsOneWidget);
      await fill(tester, 'Password', 'nope');
      expect(find.text('Wrong username or password.'), findsOneWidget);
      await fill(tester, 'Password', 'secret');
      expect(find.text('Allow Audiobookshelf to use your account?'), findsOne);
      await tester.tap(find.text('Allow'));
      await tester.pumpAndSettle();
    }, () => servers.client);

    expect(find.text('Hello wear'), findsOneWidget);
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getString('token'), 'legacy-token');
    expect(prefs.getString('username'), 'wear');
    expect(prefs.getString('serverUrl'), fakeAbsUrl);
    expect(prefs.getString('defaultLibraryId'), 'lib1');
  });

  testWidgets('says why SSO cannot start, under the button', (tester) async {
    final servers = FakeServers(startStatus: 400);
    await http.runWithClient(() => startSso(tester), () => servers.client);
    expect(
      find.text(
        'Ask the server admin to allow abswear://oauth under Allowed Mobile '
        'Redirect URIs.',
      ),
      findsOneWidget,
    );
    // Still at the choice.
    expect(find.text('Login with password'), findsOneWidget);
  });

  testWidgets('cancel goes back to the choice', (tester) async {
    final servers = FakeServers();
    await http.runWithClient(() async {
      await startSso(tester);
      await tester.ensureVisible(find.text('Cancel'));
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
    }, () => servers.client);
    expect(find.text('Login with password'), findsOneWidget);
    expect(find.text('Login with SSO'), findsOneWidget);
  });

  Future<void> next(WidgetTester tester) async {
    await tester.pumpApp(const LoginPage());
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextFormField).first, fakeAbsUrl);
    await tester.tap(find.text('Next'));
    await tester.pumpAndSettle();
  }

  testWidgets('an SSO-only server goes straight to SSO', (tester) async {
    final servers = FakeServers(password: false);
    await http.runWithClient(() => next(tester), () => servers.client);
    // The identity provider's first screen, and who is asking.
    expect(find.text('Authentik'), findsOneWidget);
    expect(find.widgetWithText(TextFormField, 'Username'), findsOneWidget);
    expect(find.text('Login with password'), findsNothing);
  });

  testWidgets('a password-only server asks for the password', (tester) async {
    final servers = FakeServers(openid: false);
    await http.runWithClient(() => next(tester), () => servers.client);
    expect(find.widgetWithText(TextFormField, 'Username'), findsOneWidget);
    expect(find.widgetWithText(TextFormField, 'Password'), findsOneWidget);
    expect(find.text('Login with SSO'), findsNothing);
    // Back to the server.
    await tester.ensureVisible(find.text('Back'));
    await tester.tap(find.text('Back'));
    await tester.pumpAndSettle();
    expect(find.text('Next'), findsOneWidget);
  });
}
