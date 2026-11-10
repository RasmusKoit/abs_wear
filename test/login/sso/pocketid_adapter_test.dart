import 'package:abs_wear/login/data/sso/pocketid_adapter.dart';
import 'package:abs_wear/login/data/sso/sso_http.dart';
import 'package:abs_wear/login/data/sso/sso_login.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../helpers/fake_pocketid_server.dart';
import '../../helpers/fake_sso_servers.dart';

TypeMatcher<SsoException> _error(SsoError error) =>
    isA<SsoException>().having((e) => e.error, 'error', error);

void main() {
  Future<(SsoLogin, SsoWait)> start(FakePocketId servers) async {
    final (login, first) = await SsoLogin.start(
      fakeAbsUrl,
      client: servers.client,
    );
    expect(login.provider, 'Pocket ID');
    expect(first, isA<SsoWait>());
    return (login, first as SsoWait);
  }

  test('approved on another device: code, wait, consent, done', () async {
    final servers = FakePocketId();
    final (login, wait) = await start(servers);
    expect(wait.code, 'PAEX5F5A');
    expect(wait.url, Uri.parse('$fakeIdpUrl/device'));
    expect(wait.poll, const Duration(seconds: 3));
    // Still pending: keep waiting.
    expect(await login.submit({}), isA<SsoWait>());
    final consent = await login.submit({});
    expect(consent, isA<SsoConsent>());
    expect((consent as SsoConsent).app, 'Audiobookshelf');
    final done = await login.submit({});
    expect(done, isA<SsoDone>());
    final user = (done as SsoDone).data['user'] as Map<String, dynamic>;
    expect(user['token'], 'legacy-token');
    expect(servers.steps, ['authenticate', 'consent']);
    expect(servers.exchanges, 2);
    login.close();
  });

  test('consent given before: straight back to the server', () async {
    final servers = FakePocketId(
      decisions: [Decision.approved],
      afterAuthenticate: null,
    );
    final (login, _) = await start(servers);
    expect(await login.submit({}), isA<SsoDone>());
    expect(servers.steps, ['authenticate']);
  });

  test('a busy server (429) means keep waiting', () async {
    final servers = FakePocketId(
      decisions: [Decision.rateLimited, Decision.approved],
      afterAuthenticate: null,
    );
    final (login, _) = await start(servers);
    expect(await login.submit({}), isA<SsoWait>());
    expect(await login.submit({}), isA<SsoDone>());
  });

  test('denied on the other device', () async {
    final servers = FakePocketId(
      decisions: [Decision.pending, Decision.denied],
    );
    final (login, _) = await start(servers);
    expect(await login.submit({}), isA<SsoWait>());
    await expectLater(
      login.submit({}),
      throwsA(
        _error(
          SsoError.accessDenied,
        ).having((e) => e.detail, 'detail', 'Device login request was denied'),
      ),
    );
  });

  test('nobody approved in time: the request expires', () async {
    final servers = FakePocketId(decisions: [Decision.expired]);
    final (login, _) = await start(servers);
    await expectLater(login.submit({}), throwsA(_error(SsoError.failed)));
  });

  test('a client that requires a fresh passkey is unsupported', () async {
    final servers = FakePocketId(
      decisions: [Decision.approved],
      afterAuthenticate: 'reauthenticate',
    );
    final (login, _) = await start(servers);
    await expectLater(
      login.submit({}),
      throwsA(_error(SsoError.unsupportedStep)),
    );
  });

  test('an interaction not starting at sign-in is unsupported', () async {
    final servers = FakePocketId(firstStep: 'reauthenticate');
    await expectLater(
      SsoLogin.start(fakeAbsUrl, client: servers.client),
      throwsA(_error(SsoError.unsupportedStep)),
    );
  });

  test('account selection is answered with the signed-in account', () async {
    final servers = FakePocketId(
      decisions: [Decision.approved],
      afterAuthenticate: 'select_account',
    );
    final (login, _) = await start(servers);
    expect(await login.submit({}), isA<SsoConsent>());
    expect(await login.submit({}), isA<SsoDone>());
    expect(servers.steps, ['authenticate', 'select_account', 'consent']);
  });

  test('a user outside the allowed groups is refused', () async {
    final servers = FakePocketId(
      decisions: [Decision.approved],
      afterAuthenticate: null,
      groupRestricted: true,
    );
    final (login, _) = await start(servers);
    await expectLater(
      login.submit({}),
      throwsA(
        _error(SsoError.accessDenied).having(
          (e) => e.detail,
          'detail',
          'You are not allowed to access this service.',
        ),
      ),
    );
  });

  group('recognises', () {
    final context = IdpContext(SsoHttp(), (_) async => (null, null));
    final interaction = Uri.parse('$fakeIdpUrl/interaction?interaction=a1');

    test("Pocket ID's authorize page", () {
      final page = SsoPage(interaction, pocketIdInteractionHtml);
      expect(PocketIdAdapter.forPage(page, context), isA<PocketIdAdapter>());
    });

    test('not an Authentik flow', () {
      final page = SsoPage(
        Uri.parse('$fakeIdpUrl/if/flow/default-authentication-flow/'),
        '<html>authentik</html>',
      );
      expect(PocketIdAdapter.forPage(page, context), isNull);
    });

    test('not a random page, even at /interaction', () {
      const html = '<html><body><form><input name="x"></form></body></html>';
      expect(
        PocketIdAdapter.forPage(SsoPage(interaction, html), context),
        isNull,
      );
      final other = Uri.parse('$fakeIdpUrl/login?interaction=a1');
      expect(
        PocketIdAdapter.forPage(
          SsoPage(other, pocketIdInteractionHtml),
          context,
        ),
        isNull,
      );
    });
  });
}
