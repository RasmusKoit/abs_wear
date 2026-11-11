import 'dart:convert';

import 'package:abs_wear/login/data/server_login.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

void main() {
  final status = jsonEncode({
    'authMethods': ['local', 'openid'],
  });

  Future<ServerLogin> fetch(
    String url,
    http.Response Function(http.Request) answer,
  ) => http.runWithClient(
    () => ServerLogin.fetch(url),
    () => MockClient((r) async {
      expect(r.followRedirects, isFalse);
      return answer(r);
    }),
  );

  test('keeps the address when the server answers there', () async {
    final login = await fetch(
      'https://abs.test',
      (_) => http.Response(status, 200),
    );
    expect(login.serverUrl, 'https://abs.test');
    expect(login.sso, isTrue);
  });

  test('follows a move to https and keeps the new address', () async {
    final login = await fetch(
      'http://abs.test',
      (r) => r.url.scheme == 'http'
          ? http.Response(
              '',
              301,
              headers: {'location': 'https://abs.test/status'},
            )
          : http.Response(status, 200),
    );
    expect(login.serverUrl, 'https://abs.test');
  });

  test('follows a move to a subfolder', () async {
    final login = await fetch(
      'https://abs.test',
      (r) => r.url.path == '/status'
          ? http.Response('', 308, headers: {'location': '/abs/status'})
          : http.Response(status, 200),
    );
    expect(login.serverUrl, 'https://abs.test/abs');
  });

  test('a redirect away from /status is an error', () async {
    await expectLater(
      fetch(
        'https://abs.test',
        (_) => http.Response('', 302, headers: {'location': '/login'}),
      ),
      throwsA(isA<ServerStatusException>()),
    );
  });

  test('a redirect loop ends', () async {
    await expectLater(
      fetch(
        'https://abs.test',
        (_) => http.Response('', 302, headers: {'location': '/status'}),
      ),
      throwsA(isA<ServerStatusException>()),
    );
  });
}
