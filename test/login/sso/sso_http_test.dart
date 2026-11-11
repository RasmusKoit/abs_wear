import 'dart:async';

import 'package:abs_wear/login/data/sso/sso_http.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;

/// Answers after [delay], unless the request is aborted first (like the
/// dart:io client does).
class _SlowClient extends http.BaseClient {
  _SlowClient(this.delay);

  final Duration delay;
  final aborted = Completer<void>();

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) {
    final answer = Completer<http.StreamedResponse>();
    final timer = Timer(delay, () {
      if (answer.isCompleted) return;
      answer.complete(http.StreamedResponse(Stream.value('ok'.codeUnits), 200));
    });
    if (request case http.Abortable(:final abortTrigger?)) {
      unawaited(
        abortTrigger.whenComplete(() {
          aborted.complete();
          timer.cancel();
          if (!answer.isCompleted) {
            answer.completeError(http.RequestAbortedException(request.url));
          }
        }),
      );
    }
    return answer.future;
  }
}

void main() {
  final url = Uri.parse('http://idp.test/api/poll');

  test('waits 20 s by default', () {
    expect(SsoHttp.timeout, const Duration(seconds: 20));
  });

  test('a longer wait lets a slow answer arrive', () async {
    final client = _SlowClient(const Duration(milliseconds: 50));
    final response = await SsoHttp(
      client,
    ).send('POST', url, wait: const Duration(seconds: 5));
    expect(response.body, 'ok');
    expect(client.aborted.isCompleted, isFalse);
  });

  test('a request that runs out of time is aborted', () async {
    final client = _SlowClient(const Duration(seconds: 5));
    await expectLater(
      SsoHttp(client).send('POST', url, wait: const Duration(milliseconds: 20)),
      throwsA(isA<TimeoutException>()),
    );
    // The server sees the request cancelled.
    await client.aborted.future.timeout(const Duration(seconds: 1));
  });
}
