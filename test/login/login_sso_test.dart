import 'dart:io';

import 'package:abs_wear/login/data/sso/phone_auth.dart';
import 'package:abs_wear/login/view/login_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../helpers/fake_pocketid_server.dart';
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
    await tester.ensureVisible(find.text('Next'));
    await tester.tap(find.text('Next'));
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

  testWidgets('a provider asking both at once still gets one per screen', (
    tester,
  ) async {
    final servers = FakeServers(passwordOnFirstPage: true);
    await http.runWithClient(() async {
      await startSso(tester);
      expect(find.byType(TextFormField), findsOneWidget);
      await fill(tester, 'Username', 'wear');
      // The password on its own screen, under the username just typed.
      expect(find.byType(TextFormField), findsOneWidget);
      expect(find.text('wear'), findsOneWidget);
      await fill(tester, 'Password', 'secret');
      expect(find.text('Allow Audiobookshelf to use your account?'), findsOne);
    }, () => servers.client);
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

  testWidgets('back from SSO returns to the choice', (tester) async {
    final servers = FakeServers();
    await http.runWithClient(() async {
      await startSso(tester);
      await tester.ensureVisible(find.text('Back'));
      await tester.tap(find.text('Back'));
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
    // One field per screen: the username, then the password.
    expect(find.byType(TextFormField), findsOneWidget);
    expect(find.widgetWithText(TextFormField, 'Username'), findsOneWidget);
    expect(find.text('Login with SSO'), findsNothing);
    await tester.enterText(find.byType(TextFormField), 'alice');
    await tester.tap(find.text('Next'));
    await tester.pumpAndSettle();
    expect(find.widgetWithText(TextFormField, 'Password'), findsOneWidget);
    expect(find.text('alice'), findsOneWidget);
    // Back, back: the username again, then the server.
    for (final field in ['Username', 'Server URL']) {
      await tester.ensureVisible(find.text('Back'));
      await tester.tap(find.text('Back'));
      await tester.pumpAndSettle();
      expect(find.widgetWithText(TextFormField, field), findsOneWidget);
    }
  });

  testWidgets("the SSO button says what the server's admin set", (
    tester,
  ) async {
    final servers = FakeServers(buttonText: '  Sign in with Authentik  ');
    await http.runWithClient(() async {
      await next(tester);
      // Trimmed, in place of the default label.
      expect(find.text('Sign in with Authentik'), findsOneWidget);
      expect(find.text('Login with SSO'), findsNothing);
      expect(find.text('Login with password'), findsOneWidget);
      // And it starts SSO.
      await tester.ensureVisible(find.text('Sign in with Authentik'));
      await tester.tap(find.text('Sign in with Authentik'));
      await tester.pumpAndSettle();
    }, () => servers.client);
    expect(find.text('Authentik'), findsOneWidget);
    expect(find.widgetWithText(TextFormField, 'Username'), findsOneWidget);
  });

  for (final (name, label) in [('an empty', ''), ('a blank', '   ')]) {
    testWidgets('$name SSO label from the server falls back to the default', (
      tester,
    ) async {
      final servers = FakeServers(buttonText: label);
      await http.runWithClient(() => next(tester), () => servers.client);
      expect(find.text('Login with SSO'), findsOneWidget);
      expect(find.text('Login with password'), findsOneWidget);
    });
  }

  testWidgets('auto launch starts SSO without the choice', (tester) async {
    final servers = FakeServers(autoLaunch: true);
    await http.runWithClient(() => next(tester), () => servers.client);
    // The identity provider's first screen, straight after Next.
    expect(find.text('Authentik'), findsOneWidget);
    expect(find.widgetWithText(TextFormField, 'Username'), findsOneWidget);
    expect(find.text('Login with password'), findsNothing);
    expect(find.text('Login with SSO'), findsNothing);
  });

  group('approving on another device (Pocket ID)', () {
    const waitText = 'On another device, enter this code: PAEX5F5A';
    // Pocket ID asks again every 3 s.
    const poll = Duration(seconds: 3);

    /// Chooses SSO, without waiting for the wait screen's spinner to stop.
    Future<void> startWait(WidgetTester tester) async {
      await next(tester);
      await tester.ensureVisible(find.text('Login with SSO'));
      await tester.tap(find.text('Login with SSO'));
      for (var i = 0; i < 10 && find.text(waitText).evaluate().isEmpty; i++) {
        await tester.pump(const Duration(milliseconds: 10));
      }
    }

    /// Error messages are shown in the theme's error colour.
    Finder errorText(WidgetTester tester) {
      final error = Theme.of(
        tester.element(find.byType(LoginPage)),
      ).colorScheme.error;
      return find.byWidgetPredicate(
        (w) => w is Text && w.style?.color == error,
      );
    }

    testWidgets('shows the code, waits, then moves on once approved', (
      tester,
    ) async {
      final servers = FakePocketId();
      await http.runWithClient(() async {
        await startWait(tester);
        expect(find.text('Pocket ID'), findsOneWidget);
        expect(find.text(waitText), findsOneWidget);
        expect(find.byType(CircularProgressIndicator), findsOneWidget);
        expect(find.byType(TextFormField), findsNothing);
        expect(servers.exchanges, 0);

        // Not approved yet: still waiting.
        await tester.pump(poll);
        await tester.pump();
        expect(servers.exchanges, 1);
        expect(find.text(waitText), findsOneWidget);
        expect(find.byType(CircularProgressIndicator), findsOneWidget);

        // Approved: Pocket ID's consent screen.
        await tester.pump(poll);
        await tester.pump();
        expect(servers.exchanges, 2);
        expect(find.text(waitText), findsNothing);
        expect(
          find.text('Allow Audiobookshelf to use your account?'),
          findsOneWidget,
        );
        await tester.ensureVisible(find.text('Allow'));
        await tester.tap(find.text('Allow'));
        await tester.pumpAndSettle();
      }, () => servers.client);
      expect(find.text('Hello wear'), findsOneWidget);
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString('token'), 'legacy-token');
    });

    testWidgets('back while waiting returns to the choice', (tester) async {
      final servers = FakePocketId(decisions: [Decision.pending]);
      await http.runWithClient(() async {
        await startWait(tester);
        expect(find.text(waitText), findsOneWidget);
        await tester.pump(poll);
        await tester.pump();
        expect(servers.exchanges, 1);
        await tester.ensureVisible(find.text('Back'));
        await tester.tap(find.text('Back'));
        await tester.pumpAndSettle();
        expect(find.text(waitText), findsNothing);
        expect(find.text('Login with password'), findsOneWidget);
        expect(find.text('Login with SSO'), findsOneWidget);
        expect(errorText(tester), findsNothing);
        // And it stops asking.
        await tester.pump(poll * 3);
        await tester.pumpAndSettle();
      }, () => servers.client);
      expect(servers.exchanges, 1);
      expect(find.text('Login with password'), findsOneWidget);
      expect(find.text(waitText), findsNothing);
      expect(errorText(tester), findsNothing);
    });
  });

  testWidgets('Back on a later field of an SSO screen goes back one field', (
    tester,
  ) async {
    final servers = FakeServers(passwordOnFirstPage: true);
    await http.runWithClient(() async {
      await startSso(tester);
      await fill(tester, 'Username', 'wear');
      expect(find.widgetWithText(TextFormField, 'Password'), findsOneWidget);
      await tester.ensureVisible(find.text('Back'));
      await tester.tap(find.text('Back'));
      await tester.pumpAndSettle();
      // The username again, still filled in; the SSO login goes on.
      expect(find.widgetWithText(TextFormField, 'Username'), findsOneWidget);
      expect(find.text('wear'), findsOneWidget);
      expect(find.text('Authentik'), findsOneWidget);
    }, () => servers.client);
  });

  testWidgets('system back steps back one login screen', (tester) async {
    final servers = FakeServers(openid: false);
    await http.runWithClient(() async {
      await tester.pumpApp(const LoginPage());
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextFormField).first, fakeAbsUrl);
      await tester.tap(find.text('Next'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextFormField), 'alice');
      await tester.tap(find.text('Next'));
      await tester.pumpAndSettle();
      expect(find.widgetWithText(TextFormField, 'Password'), findsOneWidget);
      // A swipe back: the username screen, then the server screen.
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(find.widgetWithText(TextFormField, 'Username'), findsOneWidget);
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(find.widgetWithText(TextFormField, 'Server URL'), findsOneWidget);
    }, () => servers.client);
  });

  group('Continue on phone', () {
    tearDown(() => LoginPageState.phoneAuth = const PhoneAuth());

    // An identity provider the watch can't drive.
    FakeServers unknownProvider() =>
        FakeServers(idpPagePath: '/realms/x/protocol/login');

    Future<void> tapContinueOnPhone(WidgetTester tester) async {
      expect(
        find.text("This sign-in can't be done on the watch yet."),
        findsOneWidget,
      );
      await tester.ensureVisible(find.text('Continue on phone'));
      await tester.tap(find.text('Continue on phone'));
    }

    testWidgets('offered when the watch cannot sign in, then logs in', (
      tester,
    ) async {
      final phone = FakePhoneAuth();
      LoginPageState.phoneAuth = phone;
      final servers = unknownProvider();
      await http.runWithClient(() async {
        await startSso(tester);
        await tapContinueOnPhone(tester);
        await tester.pumpAndSettle();
      }, () => servers.client);
      expect(phone.opened.single.queryParameters['redirect_uri'], fakeRelayUri);
      expect(find.text('Hello wear'), findsOneWidget);
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString('token'), 'legacy-token');
    });

    testWidgets('no phone to continue on', (tester) async {
      LoginPageState.phoneAuth = FakePhoneAuth(
        error: PhoneAuthError.phoneUnavailable,
      );
      final servers = unknownProvider();
      await http.runWithClient(() async {
        await startSso(tester);
        await tapContinueOnPhone(tester);
        await tester.pumpAndSettle();
      }, () => servers.client);
      expect(
        find.text(
          'No phone to continue on. Pair an Android phone, or log in with '
          'a password.',
        ),
        findsOneWidget,
      );
      expect(find.text('Login with password'), findsOneWidget);
    });

    testWidgets('Back while waiting stops it', (tester) async {
      final phone = FakePhoneAuth(hang: true);
      LoginPageState.phoneAuth = phone;
      final servers = unknownProvider();
      await http.runWithClient(() async {
        await startSso(tester);
        await tapContinueOnPhone(tester);
        // Not pumpAndSettle: the spinner never settles, and settling would
        // run the clock up to the 10-minute limit.
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 100));
        expect(find.text('Finish signing in on your phone.'), findsOneWidget);
        await tester.tap(find.text('Back'));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 100));
      }, () => servers.client);
      expect(phone.cancels, 1);
      expect(find.text('Finish signing in on your phone.'), findsNothing);
      expect(find.text('Login with password'), findsOneWidget);
      // Cancelling is not an error.
      expect(find.text('SSO login failed. Try again.'), findsNothing);
    });
  });
}
