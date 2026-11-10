import 'dart:async';
import 'dart:convert' show jsonDecode, jsonEncode;

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;

import 'fake_sso_servers.dart';

const _interaction = 'a799eee1-3bca-48d1-9248-958d5cab5497';
const _request = 'PAEX5F5A';

/// Pocket ID's authorize page for the fake's interaction.
const pocketIdInteractionUrl =
    '$fakeIdpUrl/interaction?interaction=$_interaction';

/// Pocket ID 2.19.2's authorize page (trimmed): a SvelteKit app whose icon
/// comes from Pocket ID's own API.
const pocketIdInteractionHtml = '''
<!doctype html>
<html lang="en">
	<head>
		<meta charset="utf-8" />
		<link rel="icon" href="/api/application-images/favicon" />
		<meta name="viewport" content="width=device-width, initial-scale=1" />
		<meta name="robots" content="noindex" />
		<link rel="manifest" href="/app.webmanifest" />
		<link href="/_app/immutable/entry/start.B6LHDBhD.js" rel="modulepreload">
	</head>
	<body data-sveltekit-preload-data="hover">
		<div style="display: contents"></div>
	</body>
</html>
''';

/// What the exchange answers, in turn (the last one repeats). [hang]
/// answers "pending" only once [FakePocketId.release] completes.
enum Decision {
  pending,
  approved,
  denied,
  expired,
  rateLimited,
  badGateway,
  unavailable,
  hang,
}

/// Pocket ID's refusal when the user isn't in the client's allowed groups.
const pocketIdGroupRefusal = 'You are not allowed to access this service.';

/// A fake Audiobookshelf + Pocket ID pair. The Pocket ID answers are trimmed
/// copies of Pocket ID 2.19.2's (hosts replaced), recorded on a real
/// "sign in with another device" login.
class FakePocketId extends FakeServers {
  FakePocketId({
    this.decisions = const [Decision.pending, Decision.approved],
    this.afterAuthenticate = 'consent',
    this.firstStep = 'authenticate',
    this.interactionError,
    this.created,
  }) : super(
         authorizeUrl:
             '$fakeIdpUrl/authorize?client_id=abs&scope=openid%20profile'
             '%20email&response_type=code&redirect_uri=x',
       );

  final List<Decision> decisions;

  /// The interaction's next step once signed in: "consent", "reauthenticate",
  /// "select_account" or null (consent given before).
  final String? afterAuthenticate;
  final String firstStep;

  /// The error Pocket ID shows instead of going back to the server, e.g.
  /// [pocketIdGroupRefusal].
  final String? interactionError;

  /// Replaces the body of the created device login request.
  final Object? created;

  int exchanges = 0;
  final steps = <String>[];

  /// Lets a [Decision.hang] exchange answer.
  final release = Completer<void>();

  Map<String, dynamic> _interactionJson(String step) => {
    'id': _interaction,
    'scopes': ['openid', 'profile', 'email'],
    'scopeInfo': <Object>[],
    'client': {
      'id': 'abs',
      'name': 'Audiobookshelf',
      'hasLogo': false,
      'hasDarkLogo': false,
      'clientType': 'standard',
    },
    'currentStep': step,
    'requiredSteps': [step],
  };

  http.Response _error(int status, String error, String code) => http.Response(
    jsonEncode({'error': error, 'code': code, 'request_id': 'r1'}),
    status,
    headers: {'content-type': 'application/json; charset=utf-8'},
  );

  @override
  Future<http.Response> handle(http.Request r) async {
    final url = r.url.toString();
    if (!url.startsWith(fakeIdpUrl)) return await super.handle(r);
    final path = r.url.path;
    final cookie = r.headers['Cookie'] ?? '';
    switch ((r.method, path)) {
      case ('GET', '/authorize'):
        if (r.url.queryParameters['interaction'] == _interaction) {
          expect(steps, isNotEmpty);
          if (interactionError case final error?) {
            return redirect(
              Uri(
                path: '/interaction/error',
                queryParameters: {'error': error},
              ).toString(),
            );
          }
          return http.Response(
            '',
            303,
            headers: {
              'location':
                  '$fakeAbsUrl/auth/openid/mobile-redirect?code=$code'
                  '&iss=http%3A%2F%2Fidp.test&scope=openid+profile+email'
                  '&state=$state',
            },
          );
        }
        return redirect('/interaction?interaction=$_interaction');
      case ('GET', '/interaction'):
        return http.Response(
          pocketIdInteractionHtml,
          200,
          headers: {'content-type': 'text/html; charset=utf-8'},
        );
      case ('GET', '/interaction/error'):
        return http.Response('<html>error</html>', 200);
      case ('GET', '/api/oidc/interactions/$_interaction'):
        return json(_interactionJson(firstStep));
      case ('POST', '/api/device-login/requests'):
        return http.Response(
          jsonEncode(
            created ??
                {
                  'id': _request,
                  'userCode': _request,
                  'verificationUri': '$fakeIdpUrl/device',
                  'verificationUriComplete':
                      '$fakeIdpUrl/device?user_code=$_request',
                  'expiresAt': '2026-11-10T21:46:16Z',
                  'interval': 3,
                },
          ),
          201,
          headers: {
            'content-type': 'application/json; charset=utf-8',
            // Five minutes before expiresAt, by the server's clock.
            'date': 'Tue, 10 Nov 2026 21:41:16 GMT',
            'set-cookie':
                'device_login_token=pVX0QsVlLjZq; '
                'Path=/api/device-login/requests/$_request/exchange; '
                'Max-Age=900; HttpOnly; Secure; SameSite=Lax',
          },
        );
      case ('POST', '/api/device-login/requests/$_request/exchange'):
        expect(cookie, contains('device_login_token=pVX0QsVlLjZq'));
        final d = decisions[exchanges.clamp(0, decisions.length - 1)];
        exchanges++;
        if (d == Decision.hang) await release.future;
        return switch (d) {
          Decision.pending || Decision.hang => http.Response('', 202),
          Decision.badGateway => http.Response('<html>Bad Gateway</html>', 502),
          Decision.unavailable => http.Response('', 503),
          Decision.rateLimited => _error(
            429,
            'Too many requests',
            'rate_limited',
          ),
          Decision.denied => _error(
            403,
            'Device login request was denied',
            'device_login_denied',
          ),
          Decision.expired => _error(
            401,
            'Device login request is invalid or expired',
            'device_login_expired',
          ),
          Decision.approved => http.Response(
            jsonEncode({
              'id': 'b31a8293-a2ca-441d-bb65-6818212c1c11',
              'username': 'wear',
              'email': 'wear@abs-wear.test',
              'emailVerified': true,
              'displayName': 'Wear Tester',
              'isAdmin': false,
              'disabled': false,
            }),
            200,
            headers: {
              'content-type': 'application/json; charset=utf-8',
              'set-cookie':
                  'access_token=eyJhbGciOi.eyJhbXIiOlsib3RwIl19.sig; '
                  'Path=/; Max-Age=3600; HttpOnly; Secure; SameSite=Lax',
            },
          ),
        };
      case ('POST', '/api/oidc/interactions/$_interaction/complete'):
        expect(cookie, contains('access_token=eyJhbGciOi'));
        final step = (jsonDecode(r.body) as Map)['step'] as String;
        steps.add(step);
        final next = switch (step) {
          'authenticate' => afterAuthenticate,
          'select_account' => 'consent',
          'consent' => null,
          _ => fail('unexpected step $step'),
        };
        if (next == null) {
          return json({'redirectUrl': '/authorize?interaction=$_interaction'});
        }
        return json({'interaction': _interactionJson(next)});
    }
    return http.Response('not found: $url', 404);
  }
}
