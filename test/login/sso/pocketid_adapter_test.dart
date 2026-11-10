import 'package:abs_wear/login/data/sso/pocketid_adapter.dart';
import 'package:abs_wear/login/data/sso/sso_http.dart';
import 'package:abs_wear/login/data/sso/sso_login.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;

import '../../helpers/fake_pocketid_server.dart';
import '../../helpers/fake_sso_servers.dart';

TypeMatcher<SsoException> _error(SsoError error) =>
    isA<SsoException>().having((e) => e.error, 'error', error);

/// Records how long each request may take.
class _RecordingHttp extends SsoHttp {
  _RecordingHttp(super.client);

  final waits = <String, Duration>{};

  @override
  Future<http.Response> send(
    String method,
    Uri url, {
    Object? body,
    Map<String, String> headers = const {},
    Duration wait = SsoHttp.timeout,
  }) {
    waits[url.path] = wait;
    return super.send(method, url, body: body, headers: headers, wait: wait);
  }
}

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

  test('a gateway error (502, 503) means keep waiting', () async {
    final servers = FakePocketId(
      decisions: [Decision.badGateway, Decision.unavailable, Decision.approved],
      afterAuthenticate: null,
    );
    final (login, _) = await start(servers);
    expect(await login.submit({}), isA<SsoWait>());
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
      interactionError: pocketIdGroupRefusal,
    );
    final (login, _) = await start(servers);
    await expectLater(
      login.submit({}),
      throwsA(
        _error(
          SsoError.accessDenied,
        ).having((e) => e.detail, 'detail', pocketIdGroupRefusal),
      ),
    );
  });

  test('other errors after sign-in are failures, not refusals', () async {
    const used = 'The interaction session has already been used.';
    final servers = FakePocketId(
      decisions: [Decision.approved],
      afterAuthenticate: null,
      interactionError: used,
    );
    final (login, _) = await start(servers);
    await expectLater(
      login.submit({}),
      throwsA(_error(SsoError.failed).having((e) => e.detail, 'detail', used)),
    );
  });

  group('an unexpected device login request', () {
    for (final (name, body) in [
      ('a list', <Object>[]),
      ('no code', {'id': 'PAEX5F5A'}),
      ('a number for an id', {'id': 1, 'userCode': 'PAEX5F5A'}),
    ]) {
      test('$name fails cleanly', () async {
        final servers = FakePocketId(created: body);
        await expectLater(
          SsoLogin.start(fakeAbsUrl, client: servers.client),
          throwsA(_error(SsoError.failed)),
        );
      });
    }

    test('a fractional interval and no expiry still work', () async {
      final servers = FakePocketId(
        created: {'id': 'PAEX5F5A', 'userCode': 'PAEX5F5A', 'interval': 5.0},
      );
      final (_, wait) = await start(servers);
      expect(wait.poll, const Duration(seconds: 5));
      expect(wait.url, isNull);
    });
  });

  group('waiting', () {
    final page = SsoPage(
      Uri.parse(pocketIdInteractionUrl),
      pocketIdInteractionHtml,
    );

    test('a status check may take 40 s, the other calls 20 s', () async {
      final servers = FakePocketId();
      final recorder = _RecordingHttp(servers.client);
      final adapter = PocketIdAdapter(
        IdpContext(recorder, (_) async => (null, null)),
      );
      await adapter.begin(page);
      expect(await adapter.submit({}), isA<SsoWait>());
      expect(recorder.waits, {
        '/api/oidc/interactions/a799eee1-3bca-48d1-9248-958d5cab5497':
            SsoHttp.timeout,
        '/api/device-login/requests': SsoHttp.timeout,
        '/api/device-login/requests/PAEX5F5A/exchange': const Duration(
          seconds: 40,
        ),
      });
    });

    test('a status check that runs out of time keeps waiting', () async {
      final servers = FakePocketId(decisions: [Decision.hang]);
      final adapter = PocketIdAdapter(
        IdpContext(SsoHttp(servers.client), (_) async => (null, null)),
        exchangeWait: const Duration(milliseconds: 20),
      );
      final first = await adapter.begin(page);
      expect(await adapter.submit({}), same(first));
      servers.release.complete();
    });

    test('Pocket ID gone for good: stops once the code expires', () async {
      var now = DateTime.utc(2026, 11, 11, 12);
      final servers = FakePocketId(decisions: [Decision.badGateway]);
      final adapter = PocketIdAdapter(
        IdpContext(SsoHttp(servers.client), (_) async => (null, null)),
        now: () => now,
      );
      await adapter.begin(page);
      // The code lasts 5 minutes by the server's clock, whatever the
      // watch's says.
      now = now.add(const Duration(minutes: 5));
      expect(await adapter.submit({}), isA<SsoWait>());
      now = now.add(const Duration(seconds: 31));
      await expectLater(
        adapter.submit({}),
        throwsA(
          _error(
            SsoError.failed,
          ).having((e) => e.detail, 'detail', 'device login expired'),
        ),
      );
    });

    test('no expiry from Pocket ID: its default 5 minutes', () async {
      var now = DateTime.utc(2026, 11, 11, 12);
      final servers = FakePocketId(
        decisions: [Decision.hang],
        created: {'id': 'PAEX5F5A', 'userCode': 'PAEX5F5A'},
      );
      final adapter = PocketIdAdapter(
        IdpContext(SsoHttp(servers.client), (_) async => (null, null)),
        now: () => now,
        exchangeWait: const Duration(milliseconds: 20),
      );
      await adapter.begin(page);
      expect(await adapter.submit({}), isA<SsoWait>());
      now = now.add(const Duration(minutes: 5, seconds: 31));
      await expectLater(adapter.submit({}), throwsA(_error(SsoError.failed)));
      servers.release.complete();
    });
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
