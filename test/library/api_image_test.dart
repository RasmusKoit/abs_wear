import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:abs_wear/library/view/api_image.dart';
import 'package:abs_wear/library/view/book_tile.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import '../helpers/helpers.dart';

const _server = 'http://abs.test';
const _url = '$_server/api/items/li_1/cover?width=40';

/// A 1x1 PNG.
final Uint8List _png = base64Decode(
  'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNkYPhfDwAChwGA'
  '60e6kgAAAABJRU5ErkJggg==',
);

void main() {
  late List<http.Request> requests;

  setUp(() {
    requests = [];
    PaintingBinding.instance.imageCache.clear();
  });

  tearDown(() => PaintingBinding.instance.imageCache.clear());

  http.Client server(http.Response Function() answer) =>
      MockClient((request) async {
        requests.add(request);
        return answer();
      });

  /// Resolves [image] and waits for its frame or its error.
  Future<Object> resolve(ApiImage image) {
    final result = Completer<Object>();
    final stream = image.resolve(ImageConfiguration.empty);
    late final ImageStreamListener listener;
    listener = ImageStreamListener(
      (info, _) {
        stream.removeListener(listener);
        result.complete(info);
      },
      onError: (error, _) {
        stream.removeListener(listener);
        result.complete(error);
      },
    );
    stream.addListener(listener);
    return result.future;
  }

  testWidgets('decodes the image, fetched with the token as WebP', (
    tester,
  ) async {
    final result = await tester.runAsync(
      () => http.runWithClient(
        () => resolve(const ApiImage(_url, 'tok')),
        () => server(() => http.Response.bytes(_png, 200)),
      ),
    );

    expect(result, isA<ImageInfo>());
    final info = result! as ImageInfo;
    expect(info.image.width, 1);
    info.dispose();
    expect(requests.single.url.toString(), _url);
    expect(requests.single.headers['Authorization'], 'Bearer tok');
    expect(requests.single.headers['Accept'], 'image/webp');
  });

  testWidgets('a failed image is fetched again next time', (tester) async {
    const image = ApiImage(_url, 'tok');
    await tester.runAsync(
      () => http.runWithClient(() async {
        expect(await resolve(image), isA<Exception>());
        // The eviction runs in a microtask.
        await Future<void>.delayed(Duration.zero);
        expect(PaintingBinding.instance.imageCache.containsKey(image), isFalse);
        await resolve(image);
      }, () => server(() => http.Response('', 404))),
    );

    expect(requests, hasLength(2));
  });

  testWidgets('a missing cover shows the placeholder', (tester) async {
    await http.runWithClient(() async {
      await tester.pumpAppInRealZone(
        const BookCover(
          serverUrl: _server,
          token: 'tok',
          bookId: 'li_1',
          size: 40,
        ),
      );
      await tester.settleRealZone(
        done: () => find.byIcon(Icons.book_rounded).evaluate().isNotEmpty,
      );
    }, () => server(() => http.Response('', 404)));

    expect(find.byIcon(Icons.book_rounded), findsOneWidget);
    expect(requests.single.url.path, '/api/items/li_1/cover');
    expect(tester.takeException(), isNull);
  });
}
