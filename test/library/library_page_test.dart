import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:abs_wear/app/continue_tile.dart';
import 'package:abs_wear/library/data/json_cache.dart';
import 'package:abs_wear/library/view/library_page.dart';
import 'package:abs_wear/player/player.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';

import '../helpers/helpers.dart';

const _server = 'http://abs.test';
const _shelfPath = '/api/libraries/lib1/personalized';

void main() {
  late Directory root;
  late List<String> requests;
  late Map<String, Future<http.Response> Function()> routes;
  late http.Client client;

  setUp(() {
    root = Directory.systemTemp.createTempSync('abs_library_page_test');
    Directory('${root.path}/docs').createSync();
    PathProviderPlatform.instance = FakePathProvider(root.path);
    fakeCrown();
    requests = [];
    routes = {};
    client = MockClient((request) async {
      final key = '${request.method} ${request.url.path}';
      requests.add(key);
      return await routes[key]?.call() ?? http.Response('', 404);
    });
  });

  tearDown(() async {
    await JsonCache.idle;
    root.deleteSync(recursive: true);
  });

  http.Response ok(Object body) => http.Response(jsonEncode(body), 200);

  Future<http.Response> offline() async =>
      throw http.ClientException('Network is unreachable');

  Map<String, Object> book(String id, String title, String author) => {
    'id': id,
    'mediaType': 'book',
    'media': {
      'metadata': {'title': title, 'authorName': author},
    },
  };

  void continueListening(List<Map<String, Object>> entities) {
    routes['GET $_shelfPath'] = () async => ok([
      {'id': 'recently-added', 'entities': <Object>[]},
      {'id': 'continue-listening', 'entities': entities},
    ]);
  }

  void libraries() {
    routes['GET /api/libraries'] = () async => ok({
      'libraries': [
        {'id': 'lib1', 'name': 'Audiobooks', 'mediaType': 'book'},
        {'id': 'lib2', 'name': 'Podcasts', 'mediaType': 'podcast'},
      ],
    });
  }

  const page = LibraryPage(
    token: 't',
    serverUrl: _server,
    libraryId: 'lib1',
    user: 'u',
  );

  /// Runs [body] with every request going to the routes above.
  Future<void> withServer(Future<void> Function() body) =>
      http.runWithClient(body, () => client);

  bool shelfLoaded() =>
      requests.contains('GET $_shelfPath') &&
      find.byType(CircularProgressIndicator).evaluate().isEmpty;

  testWidgets('shows a spinner until the server answers', (tester) async {
    final answer = Completer<http.Response>();
    routes['GET $_shelfPath'] = () => answer.future;
    await withServer(() async {
      await tester.pumpAppInRealZone(page);
      await tester.settleRealZone(
        done: () => requests.contains('GET $_shelfPath'),
      );

      expect(find.text('Continue Listening'), findsOneWidget);
      expect(find.byType(CircularProgressIndicator), findsWidgets);
      expect(find.text('Nothing in progress.'), findsNothing);

      answer.complete(ok(const <Object>[]));
      await tester.settleRealZone(done: shelfLoaded);
    });
    expect(find.text('Nothing in progress.'), findsOneWidget);
  });

  testWidgets('lists Continue Listening under the library name', (
    tester,
  ) async {
    libraries();
    continueListening([
      book('li_1', 'Dune', 'Frank Herbert'),
      {
        'id': 'pod_1',
        'mediaType': 'podcast',
        'media': {
          'metadata': {'title': 'The Show'},
        },
        'recentEpisode': {'id': 'ep_1', 'title': 'Episode 1'},
      },
    ]);
    await withServer(() async {
      await tester.pumpAppInRealZone(page);
      await tester.settleRealZone(done: shelfLoaded);
    });

    expect(find.text('Audiobooks'), findsOneWidget);
    expect(find.text('Dune'), findsOneWidget);
    expect(find.text('Frank Herbert'), findsOneWidget);
    expect(find.text('Episode 1'), findsOneWidget);
    expect(find.text('The Show'), findsOneWidget);
    expect(find.text('All books'), findsOneWidget);
    // Two libraries: the switcher shows.
    expect(find.text('Libraries'), findsOneWidget);
    expect(find.textContaining('Offline'), findsNothing);
    // No downloads for this server: no Downloads entry.
    expect(find.text('Downloads'), findsNothing);
  });

  testWidgets('says so when nothing is in progress', (tester) async {
    routes['GET $_shelfPath'] = () async => ok([
      {'id': 'recently-added', 'entities': <Object>[]},
    ]);
    await withServer(() async {
      await tester.pumpAppInRealZone(page);
      await tester.settleRealZone(done: shelfLoaded);
    });

    expect(find.text('Nothing in progress.'), findsOneWidget);
    expect(find.text('Library'), findsOneWidget, reason: 'no library name');
    expect(find.text('Libraries'), findsNothing);
  });

  testWidgets('without a saved list, shows why loading failed', (tester) async {
    routes['GET $_shelfPath'] = offline;
    await withServer(() async {
      await tester.pumpAppInRealZone(page);
      await tester.settleRealZone(done: shelfLoaded);
    });

    expect(find.text("Can't reach the server."), findsOneWidget);
    expect(find.textContaining('Offline'), findsNothing);
  });

  testWidgets('a server error shows the generic message', (tester) async {
    routes['GET $_shelfPath'] = () async => http.Response('', 500);
    await withServer(() async {
      await tester.pumpAppInRealZone(page);
      await tester.settleRealZone(done: shelfLoaded);
    });

    expect(find.text('Error loading data'), findsOneWidget);
  });

  group('offline', () {
    /// Opens the page online once, so the shelf and libraries are saved,
    /// then leaves it.
    Future<void> visitOnline(WidgetTester tester) async {
      libraries();
      continueListening([book('li_1', 'Dune', 'Frank Herbert')]);
      await tester.pumpAppInRealZone(page);
      await tester.settleRealZone(done: shelfLoaded);
      expect(find.text('Dune'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
      // What it saved is on disk before the next visit reads it.
      await tester.runAsync(() => JsonCache.idle);
    }

    testWidgets('shows the saved list with the offline banner', (tester) async {
      await withServer(() async {
        await visitOnline(tester);
        routes['GET $_shelfPath'] = offline;
        routes['GET /api/libraries'] = offline;
        requests.clear();

        await tester.pumpAppInRealZone(page);
        await tester.settleRealZone(done: shelfLoaded);
      });

      expect(requests, contains('GET $_shelfPath'));
      expect(find.text('Dune'), findsOneWidget);
      expect(find.text('Audiobooks'), findsOneWidget);
      expect(
        find.text('Offline. Showing the saved list. Tap to retry.'),
        findsOneWidget,
      );
      expect(find.text("Can't reach the server."), findsNothing);
    });

    testWidgets('tapping the banner retries', (tester) async {
      await withServer(() async {
        await visitOnline(tester);
        routes['GET $_shelfPath'] = offline;
        await tester.pumpAppInRealZone(page);
        await tester.settleRealZone(done: shelfLoaded);
        final banner = find.text(
          'Offline. Showing the saved list. Tap to retry.',
        );
        expect(banner, findsOneWidget);

        // Back online.
        continueListening([
          book('li_1', 'Dune', 'Frank Herbert'),
          book('li_2', 'Emma', 'Jane Austen'),
        ]);
        requests.clear();
        await tester.tapInRealZone(banner);
        await tester.settleRealZone(done: shelfLoaded);
      });

      expect(requests, contains('GET $_shelfPath'));
      expect(find.textContaining('Offline'), findsNothing);
      expect(find.text('Emma'), findsOneWidget);
    });
  });

  testWidgets('shows Downloads when this server has some', (tester) async {
    final dir = Directory('${root.path}/docs/li_9')..createSync();
    File(
      '${dir.path}/session.json',
    ).writeAsStringSync(jsonEncode({'server': _server, 'itemId': 'li_9'}));
    routes['GET $_shelfPath'] = offline;
    await withServer(() async {
      await tester.pumpAppInRealZone(page);
      await tester.settleRealZone(
        done: () => find.text('Downloads').evaluate().isNotEmpty,
      );
    });

    expect(find.text('Downloads'), findsOneWidget);
  });

  group('closes itself for the login page', () {
    Future<LibraryResult?> openAndWait(WidgetTester tester) async {
      late Future<LibraryResult?> result;
      await withServer(() async {
        await tester.pumpAppInRealZone(const Text('home'));
        await tester.runAsync(() async {
          result = tester
              .state<NavigatorState>(find.byType(Navigator))
              .push(MaterialPageRoute<LibraryResult>(builder: (_) => page));
          await tester.pump();
        });
        await tester.settleRealZone(
          done: () => find.byType(LibraryPage).evaluate().isEmpty,
        );
      });
      await tester.pumpAndSettle();
      return await tester.runAsync<LibraryResult?>(() => result);
    }

    testWidgets('on 401: the session expired', (tester) async {
      routes['GET $_shelfPath'] = () async => http.Response('', 401);

      expect(await openAndWait(tester), LibraryResult.sessionExpired);
      expect(find.text('home'), findsOneWidget);
    });

    testWidgets('on 404: the library is gone', (tester) async {
      routes['GET $_shelfPath'] = () async => http.Response('', 404);

      expect(await openAndWait(tester), LibraryResult.libraryMissing);
    });
  });

  group('Continue listening tile', () {
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    late List<String> calls;
    late Map<String, Object?>? pending;
    PlayerPage? player;

    setUp(() {
      calls = [];
      pending = null;
      player = null;
      messenger.setMockMethodCallHandler(ContinueTile.channel, (call) async {
        calls.add(call.method);
        if (call.method != 'take') return null;
        final open = pending;
        pending = null;
        return open;
      });
    });

    tearDown(
      () => messenger.setMockMethodCallHandler(ContinueTile.channel, null),
    );

    // The player closes again when its session fails, so keep what opened.
    bool Function() playerShows(WidgetTester tester) => () {
      final found = find.byType(PlayerPage, skipOffstage: false);
      if (found.evaluate().isNotEmpty) player ??= tester.widget(found);
      return player != null;
    };

    testWidgets('a tap at start opens the player for that book', (
      tester,
    ) async {
      pending = {'id': 'pod_1', 'episodeId': 'ep_1'};
      continueListening([book('li_1', 'Dune', 'Frank Herbert')]);
      await withServer(() async {
        await tester.pumpAppInRealZone(page);
        await tester.settleRealZone(done: playerShows(tester));
      });

      expect(player?.libraryItemId, 'pod_1');
      expect(player?.episodeId, 'ep_1');
      await tester.runAsync(() => tester.pumpWidget(const SizedBox()));
    });

    testWidgets('a tap while running opens the player', (tester) async {
      continueListening([book('li_1', 'Dune', 'Frank Herbert')]);
      await withServer(() async {
        await tester.pumpAppInRealZone(page);
        await tester.settleRealZone(done: shelfLoaded);
        expect(playerShows(tester)(), isFalse);

        pending = {'id': 'li_1'};
        await tester.runAsync(
          () => simulatePlatformCall(ContinueTile.channel.name, 'open'),
        );
        await tester.settleRealZone(done: playerShows(tester));
      });

      expect(player?.libraryItemId, 'li_1');
      expect(player?.episodeId, isNull);
      await tester.runAsync(() => tester.pumpWidget(const SizedBox()));
    });

    testWidgets('a new shelf refreshes the tile', (tester) async {
      continueListening([book('li_1', 'Dune', 'Frank Herbert')]);
      await withServer(() async {
        await tester.pumpAppInRealZone(page);
        await tester.settleRealZone(done: () => calls.contains('refresh'));
      });

      expect(calls, contains('refresh'));
      final saved = await tester.runAsync(
        () => JsonCache.read('shelf_${'$_server|u'.hashCode}_lib1'),
      );
      expect(saved, [
        {'i': 'li_1', 't': 'Dune', 'a': 'Frank Herbert'},
      ]);
    });
  });
}
