import 'dart:convert';

import 'package:abs_wear/login/data/sso/logto_adapter.dart';
import 'package:abs_wear/login/data/sso/sso_http.dart';
import 'package:abs_wear/login/data/sso/sso_login.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import '../../helpers/fake_logto_server.dart';
import '../../helpers/fake_sso_servers.dart';

const List<SsoField> _login = [SsoField.username, SsoField.password];
const Map<SsoField, String> _right = {
  SsoField.username: 'wear',
  SsoField.password: 'secret',
};

Future<(SsoLogin, SsoStep)> _start(FakeLogto servers) =>
    SsoLogin.start(fakeAbsUrl, client: servers.client);

Matcher _prompt(List<SsoField> fields, {bool retry = false, String? user}) =>
    isA<SsoPrompt>()
        .having((p) => p.fields, 'fields', fields)
        .having((p) => p.retry, 'retry', retry)
        .having((p) => p.user, 'user', user);

Matcher _error(SsoError error, [String? detail]) => isA<SsoException>()
    .having((e) => e.error, 'error', error)
    .having((e) => e.detail, 'detail', detail ?? anything);

void main() {
  test('logs in with a username and password', () async {
    final servers = FakeLogto();
    final (login, first) = await _start(servers);
    expect(login.provider, 'Logto');
    expect(first, _prompt(_login));
    final done = await login.submit(_right);
    expect(done, isA<SsoDone>());
    final data = (done as SsoDone).data;
    expect((data['user'] as Map)['token'], 'legacy-token');
    // The password went to Logto's password check and nowhere else.
    final withPassword = [
      for (final r in servers.requests)
        if (r.body.contains('secret')) '${r.method} ${r.url}',
    ];
    expect(withPassword, [
      'POST $fakeIdpUrl/api/experience/verification/password',
    ]);
    login.close();
  });

  test('a wrong password asks for both again', () async {
    final servers = FakeLogto();
    final (login, _) = await _start(servers);
    final again = await login.submit({
      SsoField.username: 'wear',
      SsoField.password: 'nope',
    });
    expect(again, _prompt(_login, retry: true));
    expect(await login.submit(_right), isA<SsoDone>());
  });

  test('asks for a TOTP code when the account has one', () async {
    final servers = FakeLogto(totp: true);
    final (login, _) = await _start(servers);
    final code = await login.submit(_right);
    expect(code, _prompt([SsoField.code], user: 'wear'));
    expect(
      await login.submit({SsoField.code: '000000'}),
      _prompt([SsoField.code], user: 'wear', retry: true),
    );
    expect(await login.submit({SsoField.code: '123456'}), isA<SsoDone>());
  });

  test('skips the suggestion to add MFA', () async {
    final servers = FakeLogto(suggestMfa: true);
    final (login, _) = await _start(servers);
    expect(await login.submit(_right), isA<SsoDone>());
    expect(
      servers.requests.map((r) => r.url.path),
      contains('/api/experience/profile/mfa/mfa-skipped'),
    );
  });

  test('skips setting up MFA when Logto allows it', () async {
    final servers = FakeLogto(mfaSetup: true, mfaSetupSkippable: true);
    final (login, _) = await _start(servers);
    expect(await login.submit(_right), isA<SsoDone>());
  });

  test("shows a third-party app's consent screen", () async {
    final servers = FakeLogto(consent: true);
    final (login, _) = await _start(servers);
    final consent = await login.submit(_right);
    expect(consent, isA<SsoConsent>());
    expect((consent as SsoConsent).app, 'Audiobookshelf');
    expect(await login.submit({}), isA<SsoDone>());
  });

  test('signs in with an email address', () async {
    final servers = FakeLogto(
      methods: [
        {...logtoUsernamePassword, 'identifier': 'email'},
      ],
    );
    final (login, first) = await _start(servers);
    expect(first, _prompt([SsoField.email, SsoField.password]));
    final done = await login.submit({
      SsoField.email: 'wear@abs-wear.test',
      SsoField.password: 'secret',
    });
    expect(done, isA<SsoDone>());
  });

  test('a sign-in page without logtoSsr is known by its cookie', () async {
    final servers = FakeLogto(ssr: false);
    final (login, first) = await _start(servers);
    expect(login.provider, 'Logto');
    expect(first, _prompt(_login));
  });

  group('unsupported', () {
    test('a CAPTCHA', () async {
      await expectLater(
        _start(FakeLogto(captcha: true)),
        throwsA(_error(SsoError.unsupportedStep, 'captcha')),
      );
    });

    test('a sign-in without a password', () async {
      final servers = FakeLogto(
        methods: [
          {
            'identifier': 'email',
            'password': false,
            'verificationCode': true,
            'isPasswordPrimary': false,
          },
        ],
      );
      await expectLater(
        _start(servers),
        throwsA(_error(SsoError.unsupportedStep)),
      );
    });

    test('a passkey as the only second factor', () async {
      final servers = FakeLogto(totp: true, factors: ['WebAuthn']);
      final (login, _) = await _start(servers);
      await expectLater(
        login.submit(_right),
        throwsA(_error(SsoError.unsupportedStep)),
      );
    });

    test('setting up MFA', () async {
      final servers = FakeLogto(mfaSetup: true);
      final (login, _) = await _start(servers);
      await expectLater(
        login.submit(_right),
        throwsA(_error(SsoError.unsupportedStep, 'user.missing_mfa')),
      );
    });

    test('choosing an organization on the consent screen', () async {
      final servers = FakeLogto(
        consent: true,
        organizations: [
          {'id': 'org1', 'name': 'Readers'},
        ],
      );
      final (login, _) = await _start(servers);
      await expectLater(
        login.submit(_right),
        throwsA(_error(SsoError.unsupportedStep, 'organizations')),
      );
    });
  });

  group('forPage', () {
    final context = IdpContext(
      SsoHttp(MockClient((_) async => http.Response('', 404))),
      (_) async => (null, null),
    );

    test("recognises Logto's sign-in page", () {
      final page = SsoPage(
        Uri.parse('$fakeIdpUrl/sign-in?app_id=abs'),
        logtoSignInPage,
      );
      expect(LogtoAdapter.forPage(page, context), isA<LogtoAdapter>());
    });

    test('ignores an Authentik flow', () {
      final page = SsoPage(
        Uri.parse('$fakeIdpUrl/if/flow/default-authentication-flow/'),
        '<html><head><title>authentik</title></head>'
        '<body><ak-flow-executor></ak-flow-executor></body></html>',
      );
      expect(LogtoAdapter.forPage(page, context), isNull);
    });

    test('ignores any other page', () {
      final page = SsoPage(
        Uri.parse('$fakeIdpUrl/sign-in'),
        '<!DOCTYPE html><form method="post"><input name="password"></form>',
      );
      expect(LogtoAdapter.forPage(page, context), isNull);
      expect(
        LogtoAdapter.forPage(
          SsoPage(Uri.parse(fakeIdpUrl), jsonEncode({'logto': 1})),
          context,
        ),
        isNull,
      );
    });
  });
}
