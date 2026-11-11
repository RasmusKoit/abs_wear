import 'dart:async';
import 'dart:io';

import 'package:abs_wear/library/data/library_api.dart';
import 'package:flutter_test/flutter_test.dart';

// Real sockets: no widget tests here, so HTTP isn't mocked.
void main() {
  late HttpServer server;
  late String url;
  final hung = <HttpResponse>[];

  setUp(() async {
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    url = 'http://${server.address.host}:${server.port}';
    server.listen((request) {
      if (request.uri.path == '/hang') {
        hung.add(request.response);
      } else {
        unawaited(request.response.close());
      }
    });
  });

  tearDown(() async {
    listTimeout = const Duration(seconds: 20);
    coverTimeout = const Duration(seconds: 60);
    for (final response in hung) {
      unawaited(response.close().catchError((_) {}));
    }
    hung.clear();
    await server.close(force: true);
  });

  test('a timeout frees the pool for later requests', () async {
    listTimeout = const Duration(milliseconds: 300);
    final stuck = [
      for (var i = 0; i < 3; i++)
        apiGet(
          '$url/hang',
          'tok',
        ).then<Object?>((_) => null, onError: (Object e) => e),
    ];

    expect(await Future.wait(stuck), everyElement(isA<TimeoutException>()));
    final response = await apiGet('$url/ok', 'tok');
    expect(response.statusCode, 200);
  });

  test('stalled covers do not hold up lists', () async {
    for (var i = 0; i < 3; i++) {
      unawaited(
        apiGet('$url/hang', 'tok', cover: true).then((_) {}, onError: (_) {}),
      );
    }
    await Future<void>.delayed(const Duration(milliseconds: 100));

    final response = await apiGet(
      '$url/ok',
      'tok',
    ).timeout(const Duration(seconds: 2));
    expect(response.statusCode, 200);
  });
}
