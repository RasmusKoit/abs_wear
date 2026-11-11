import 'package:abs_wear/login/data/sso/authentik_adapter.dart';
import 'package:abs_wear/login/data/sso/sso_http.dart';
import 'package:abs_wear/login/data/sso/sso_login.dart';
import 'package:abs_wear/login/data/sso/voidauth_adapter.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../helpers/fake_sso_servers.dart';
import '../../helpers/fake_voidauth_server.dart';

const _login = <SsoField>[SsoField.username, SsoField.password];

Future<(SsoLogin, SsoStep)> _start(FakeVoidAuthServers servers) =>
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
  test('logs in through VoidAuth: password, consent', () async {
    final servers = FakeVoidAuthServers();
    final (login, first) = await _start(servers);
    expect(login.provider, 'VoidAuth');
    expect(first, _prompt(_login));
    final consent = await login.submit({
      SsoField.username: 'wear',
      SsoField.password: 'secret',
    });
    expect(consent, isA<SsoConsent>());
    expect((consent as SsoConsent).app, 'Audiobookshelf');
    final done = await login.submit({});
    expect(servers.consented, isTrue);
    expect(done, isA<SsoDone>());
    expect(((done as SsoDone).data['user'] as Map)['token'], 'legacy-token');
    login.close();
  });

  test('consent given before goes straight back to the server', () async {
    final servers = FakeVoidAuthServers(next: VoidAuthNext.done);
    final (login, _) = await _start(servers);
    expect(
      await login.submit({
        SsoField.username: 'wear',
        SsoField.password: 'secret',
      }),
      isA<SsoDone>(),
    );
  });

  test('a wrong password asks for both fields again', () async {
    final servers = FakeVoidAuthServers();
    final (login, _) = await _start(servers);
    expect(
      await login.submit({
        SsoField.username: 'wear',
        SsoField.password: 'nope',
      }),
      _prompt(_login, retry: true),
    );
    expect(
      await login.submit({
        SsoField.username: 'wear',
        SsoField.password: 'secret',
      }),
      isA<SsoConsent>(),
    );
  });

  test('asks for a TOTP code, again after a wrong one', () async {
    final servers = FakeVoidAuthServers(next: VoidAuthNext.totp);
    final (login, _) = await _start(servers);
    expect(
      await login.submit({
        SsoField.username: 'wear',
        SsoField.password: 'secret',
      }),
      _prompt([SsoField.code], user: 'wear'),
    );
    expect(
      await login.submit({SsoField.code: '000000'}),
      _prompt([SsoField.code], user: 'wear', retry: true),
    );
    expect(await login.submit({SsoField.code: '123456'}), isA<SsoConsent>());
    expect(await login.submit({}), isA<SsoDone>());
  });

  test('works when VoidAuth runs under a subpath', () async {
    final servers = FakeVoidAuthServers(base: '/auth/');
    final (login, first) = await _start(servers);
    expect(first, _prompt(_login));
    await login.submit({
      SsoField.username: 'wear',
      SsoField.password: 'secret',
    });
    expect(await login.submit({}), isA<SsoDone>());
  });

  Future<void> passwordThen(
    VoidAuthNext next,
    Matcher error, {
    Map<String, int> fail = const {},
    String? meBody,
  }) async {
    final servers = FakeVoidAuthServers(next: next, fail: fail, meBody: meBody);
    final (login, _) = await _start(servers);
    await expectLater(
      login.submit({SsoField.username: 'wear', SsoField.password: 'secret'}),
      throwsA(error),
    );
  }

  test('a passkey-only second factor is unsupported on the watch', () async {
    await passwordThen(
      VoidAuthNext.passkey,
      _error(SsoError.unsupportedStep, 'passkey'),
    );
  });

  test('email verification is unsupported on the watch', () async {
    await passwordThen(
      VoidAuthNext.verifyEmail,
      _error(SsoError.unsupportedStep, 'verification_email_sent'),
    );
  });

  test('an account waiting for approval is denied', () async {
    await passwordThen(VoidAuthNext.approval, _error(SsoError.accessDenied));
  });

  test('an expired or forbidden account is denied', () async {
    await passwordThen(
      VoidAuthNext.userExpired,
      _error(SsoError.accessDenied, 'user_expired'),
    );
    await passwordThen(
      VoidAuthNext.forbidden,
      _error(SsoError.accessDenied, 'forbidden'),
    );
  });

  test('a required second factor not set up yet is unsupported', () async {
    await passwordThen(
      VoidAuthNext.mfaSetup,
      _error(SsoError.unsupportedStep, 'mfa setup'),
    );
  });

  test('an expired login fails', () async {
    await passwordThen(
      VoidAuthNext.consent,
      _error(SsoError.failed, 'voidauth 419'),
      fail: {'login': 419},
    );
  });

  test('an /me answer that is not a JSON object fails cleanly', () async {
    for (final body in [voidAuthPage, '[]']) {
      await passwordThen(
        VoidAuthNext.totp,
        _error(SsoError.failed, 'voidauth: bad /me'),
        meBody: body,
      );
    }
  });

  test('too many wrong codes fails instead of asking again', () async {
    final servers = FakeVoidAuthServers(
      next: VoidAuthNext.totp,
      fail: {'totp': 423},
    );
    final (login, _) = await _start(servers);
    await login.submit({
      SsoField.username: 'wear',
      SsoField.password: 'secret',
    });
    await expectLater(
      login.submit({SsoField.code: '123456'}),
      throwsA(_error(SsoError.failed, 'voidauth 423')),
    );
  });

  test('a consent confirm that does not redirect fails', () async {
    for (final status in [419, 400]) {
      final servers = FakeVoidAuthServers(fail: {'confirm': status});
      final (login, _) = await _start(servers);
      await login.submit({
        SsoField.username: 'wear',
        SsoField.password: 'secret',
      });
      await expectLater(
        login.submit({}),
        throwsA(_error(SsoError.failed, 'voidauth $status')),
      );
      expect(servers.consented, isFalse);
    }
  });

  test('an unusable consent detail falls back to a default name', () async {
    for (final body in [voidAuthPage, '[]', '{"clientName": 7}']) {
      final servers = FakeVoidAuthServers(detailBody: body);
      final (login, _) = await _start(servers);
      final consent = await login.submit({
        SsoField.username: 'wear',
        SsoField.password: 'secret',
      });
      expect(consent, isA<SsoConsent>());
      expect((consent as SsoConsent).app, 'Audiobookshelf');
    }
  });

  group('forPage', () {
    final context = IdpContext(SsoHttp(), (_) async => (null, null));
    SsoPage page(String url, String body) => SsoPage(Uri.parse(url), body);

    test("recognises VoidAuth's login page", () {
      expect(
        VoidAuthAdapter.forPage(
          page('$fakeIdpUrl/login', voidAuthPage),
          context,
        ),
        isA<VoidAuthAdapter>(),
      );
    });

    test('finds the app under its base href', () {
      final html = voidAuthPage.replaceFirst('href="/"', 'href="/auth/"');
      final p = page('$fakeIdpUrl/auth/login', html);
      expect(VoidAuthAdapter.appBase(p), Uri.parse('$fakeIdpUrl/auth/'));
      expect(VoidAuthAdapter.forPage(p, context), isNotNull);
    });

    test('ignores a base href on another server', () {
      final html = voidAuthPage.replaceFirst(
        'href="/"',
        'href="http://elsewhere.test/"',
      );
      expect(
        VoidAuthAdapter.forPage(page('$fakeIdpUrl/login', html), context),
        isNull,
      );
    });

    test('ignores Authentik, other pages and other Angular apps', () {
      final authentik = page(
        '$fakeIdpUrl/if/flow/default-authentication-flow/?next=%2F',
        '<html><head><title>authentik</title></head>'
            '<body><ak-flow-executor></ak-flow-executor></body></html>',
      );
      expect(VoidAuthAdapter.forPage(authentik, context), isNull);
      expect(
        VoidAuthAdapter.forPage(
          page('$fakeIdpUrl/login', '<html><body>Sign in</body></html>'),
          context,
        ),
        isNull,
      );
      expect(
        VoidAuthAdapter.forPage(
          page('$fakeIdpUrl/login', '<base href="/"><app-root></app-root>'),
          context,
        ),
        isNull,
      );
      // VoidAuth's other pages are reached only through its login.
      expect(
        VoidAuthAdapter.forPage(page('$fakeIdpUrl/mfa', voidAuthPage), context),
        isNull,
      );
      expect(
        AuthentikAdapter.forPage(
          page('$fakeIdpUrl/login', voidAuthPage),
          context,
        ),
        isNull,
      );
    });
  });
}
