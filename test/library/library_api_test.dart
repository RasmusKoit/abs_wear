import 'dart:async';
import 'dart:convert';

import 'package:abs_wear/l10n/gen/app_localizations_en.dart';
import 'package:abs_wear/library/data/library_api.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

const _server = 'http://abs.test';

void main() {
  late List<http.Request> requests;

  setUp(() => requests = []);

  /// Runs [body] with a client that answers every request with [answer].
  Future<T> withServer<T>(
    Future<T> Function() body,
    Future<http.Response> Function(http.Request request) answer,
  ) => http.runWithClient(
    body,
    () => MockClient((request) {
      requests.add(request);
      return answer(request);
    }),
  );

  http.Response ok(Object body) => http.Response(jsonEncode(body), 200);

  group('ShelfBook.fromJson', () {
    test('a book shows its title and author name', () {
      final book = ShelfBook.fromJson(const {
        'id': 'li_1',
        'mediaType': 'book',
        'media': {
          'metadata': {
            'title': 'Dune',
            'authorName': 'Frank Herbert',
            'author': 'ignored for books',
          },
        },
      });

      expect(book.id, 'li_1');
      expect(book.title, 'Dune');
      expect(book.author, 'Frank Herbert');
      expect(book.isPodcast, isFalse);
      expect(book.episodeId, isNull);
    });

    test('a podcast shows its author field', () {
      final podcast = ShelfBook.fromJson(const {
        'id': 'pod_1',
        'mediaType': 'podcast',
        'media': {
          'metadata': {'title': 'The Show', 'author': 'Host'},
        },
      });

      expect(podcast.title, 'The Show');
      expect(podcast.author, 'Host');
      expect(podcast.isPodcast, isTrue);
      expect(podcast.episodeId, isNull);
    });

    test('a shelf entry with a recent episode is that episode', () {
      final episode = ShelfBook.fromJson(const {
        'id': 'pod_1',
        'mediaType': 'podcast',
        'media': {
          'metadata': {'title': 'The Show', 'author': 'Host'},
        },
        'recentEpisode': {'id': 'ep_7', 'title': 'Episode 7'},
      });

      expect(episode.id, 'pod_1', reason: 'the podcast to play from');
      expect(episode.episodeId, 'ep_7');
      expect(episode.title, 'Episode 7');
      expect(episode.author, 'The Show', reason: 'the podcast as subtitle');
      expect(episode.isPodcast, isTrue);
    });

    test('a recent episode without an id is ignored', () {
      final podcast = ShelfBook.fromJson(const {
        'id': 'pod_1',
        'mediaType': 'podcast',
        'media': {
          'metadata': {'title': 'The Show'},
        },
        'recentEpisode': {'title': 'No id'},
      });

      expect(podcast.title, 'The Show');
      expect(podcast.episodeId, isNull);
    });

    test('missing metadata gives empty strings', () {
      final book = ShelfBook.fromJson(const {'id': 'li_1'});

      expect(book.title, '');
      expect(book.author, '');
      expect(book.isPodcast, isFalse);
    });
  });

  group('ShelfBook cache form', () {
    test('a book survives the round trip', () {
      const book = ShelfBook(id: 'li_1', title: 'Dune', author: 'Herbert');

      final back = ShelfBook.fromCache(
        jsonDecode(jsonEncode(book.toCache())) as Map<String, dynamic>,
      );

      expect(back.id, 'li_1');
      expect(back.title, 'Dune');
      expect(back.author, 'Herbert');
      expect(back.isPodcast, isFalse);
      expect(back.episodeId, isNull);
    });

    test('a podcast episode survives the round trip', () {
      const episode = ShelfBook(
        id: 'pod_1',
        title: 'Episode 7',
        author: 'The Show',
        isPodcast: true,
        episodeId: 'ep_7',
      );

      final back = ShelfBook.fromCache(
        jsonDecode(jsonEncode(episode.toCache())) as Map<String, dynamic>,
      );

      expect(back.isPodcast, isTrue);
      expect(back.episodeId, 'ep_7');
      expect(back.title, 'Episode 7');
    });

    test('a book leaves out the podcast fields', () {
      const book = ShelfBook(id: 'li_1', title: 'Dune', author: 'Herbert');
      expect(book.toCache().keys, unorderedEquals(['i', 't', 'a']));
    });
  });

  group('fetchLibraries', () {
    test('lists book and podcast libraries with the token', () async {
      final libraries = await withServer(
        () => fetchLibraries(_server, 'tok'),
        (_) async => ok({
          'libraries': [
            {'id': 'b', 'name': 'Books', 'mediaType': 'book'},
            {'id': 'p', 'name': 'Podcasts', 'mediaType': 'podcast'},
            {'id': 'x', 'name': 'Comics', 'mediaType': 'comic'},
          ],
        }),
      );

      expect(requests.single.method, 'GET');
      expect(requests.single.url.toString(), '$_server/api/libraries');
      expect(requests.single.headers['Authorization'], 'Bearer tok');
      expect([for (final l in libraries) l.id], ['b', 'p']);
      expect(libraries[0].name, 'Books');
      expect(libraries[0].isPodcast, isFalse);
      expect(libraries[1].isPodcast, isTrue);
    });

    test('a library survives the cache round trip', () {
      const library = LibraryInfo(id: 'p', name: 'Pods', isPodcast: true);

      final back = LibraryInfo.fromJson(
        jsonDecode(jsonEncode(library.toJson())) as Map<String, dynamic>,
      );

      expect(back.id, 'p');
      expect(back.name, 'Pods');
      expect(back.isPodcast, isTrue);
    });

    test('a server error is thrown as ApiException', () async {
      await expectLater(
        withServer(
          () => fetchLibraries(_server, 'tok'),
          (_) async => http.Response('', 500),
        ),
        throwsA(isA<ApiException>().having((e) => e.statusCode, 'code', 500)),
      );
    });
  });

  group('getJson', () {
    test('decodes the body of a 200', () async {
      final json = await withServer(
        () => getJson('$_server/api/items/li_1?expanded=1', 'tok'),
        (_) async => ok({'id': 'li_1'}),
      );

      expect(json, {'id': 'li_1'});
      expect(requests.single.url.queryParameters, {'expanded': '1'});
      expect(requests.single.headers['Authorization'], 'Bearer tok');
    });

    test('maps 401 to an expired session and 404 to a missing library', () {
      expect(const ApiException(401).result, LibraryResult.sessionExpired);
      expect(const ApiException(404).result, LibraryResult.libraryMissing);
      expect(const ApiException(500).result, isNull);
      expect(const ApiException(403).result, isNull);
    });

    for (final code in [401, 404, 500, 502]) {
      test('throws ApiException($code) for a $code reply', () async {
        await expectLater(
          withServer(
            () => getJson('$_server/api/libraries', 'tok'),
            (_) async => http.Response('{"error": true}', code),
          ),
          throwsA(
            isA<ApiException>().having((e) => e.statusCode, 'code', code),
          ),
        );
      });
    }

    test('a network failure is thrown as is', () async {
      await expectLater(
        withServer(
          () => getJson('$_server/api/libraries', 'tok'),
          (request) async =>
              throw http.ClientException('Failed host lookup', request.url),
        ),
        throwsA(isA<http.ClientException>()),
      );
    });

    test('a body that is not JSON throws', () async {
      await expectLater(
        withServer(
          () => getJson('$_server/api/libraries', 'tok'),
          (_) async => http.Response('<html>proxy login</html>', 200),
        ),
        throwsA(isA<FormatException>()),
      );
    });

    testWidgets('gives up after 20 seconds without an answer', (tester) async {
      final never = Completer<http.Response>();
      Object? error;
      unawaited(
        withServer(
          () => getJson('$_server/api/libraries', 'tok'),
          (_) => never.future,
        ).then<void>((_) {}, onError: (Object e) => error = e),
      );

      await tester.pump(const Duration(seconds: 19));
      expect(error, isNull);
      await tester.pump(const Duration(seconds: 2));
      expect(error, isA<TimeoutException>());
    });
  });

  group('errorMessage', () {
    final l10n = AppLocalizationsEn();

    test('a timeout says the server did not respond', () {
      expect(errorMessage(l10n, TimeoutException('x')), l10n.serverTimeout);
    });

    test('no network says the server cannot be reached', () {
      expect(
        errorMessage(l10n, http.ClientException('Connection refused')),
        l10n.cannotReachServer,
      );
    });

    test('a server error or bad reply is an error loading data', () {
      expect(
        errorMessage(l10n, const ApiException(500)),
        l10n.errorLoadingData,
      );
      expect(
        errorMessage(l10n, const FormatException('bad')),
        l10n.errorLoadingData,
      );
      expect(errorMessage(l10n, null), l10n.errorLoadingData);
    });
  });
}
