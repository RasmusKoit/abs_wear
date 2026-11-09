import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:abs_wear/library/data/json_cache.dart';
import 'package:abs_wear/library/data/library_api.dart';
import 'package:abs_wear/library/view/episodes_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';

import '../helpers/helpers.dart';

const _server = 'http://abs.test';
const _itemPath = '/api/items/pod_1';
const _banner = 'Offline. Showing the saved list. Tap to retry.';

void main() {
  late Directory root;
  late List<Uri> requests;
  late Map<String, Future<http.Response> Function()> routes;
  late http.Client client;

  setUp(() {
    root = Directory.systemTemp.createTempSync('abs_episodes_test');
    PathProviderPlatform.instance = FakePathProvider(root.path);
    fakeCrown();
    requests = [];
    routes = {};
    client = MockClient((request) async {
      requests.add(request.url);
      final key = '${request.method} ${request.url.path}';
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

  final day = DateTime(2026, 11, 8).millisecondsSinceEpoch;

  void episodes(List<(String, String, int)> list) {
    routes['GET $_itemPath'] = () async => ok({
      'id': 'pod_1',
      'media': {
        'episodes': [
          for (final (id, title, published) in list)
            {'id': id, 'title': title, 'publishedAt': published},
        ],
      },
    });
  }

  const page = EpisodesPage(
    serverUrl: _server,
    token: 't',
    user: 'u',
    podcast: ShelfBook(
      id: 'pod_1',
      title: 'The Show',
      author: 'Host',
      isPodcast: true,
    ),
  );

  Future<void> withServer(Future<void> Function() body) =>
      http.runWithClient(body, () => client);

  bool loaded() =>
      requests.any((u) => u.path == _itemPath) &&
      find.byType(CircularProgressIndicator).evaluate().isEmpty;

  /// The episode titles in list order.
  List<String> titles() => [
    for (final e
        in find
            .descendant(of: find.byType(ListView), matching: find.byType(Text))
            .evaluate())
      (e.widget as Text).data ?? '',
  ].where((t) => t.startsWith('Ep')).toList();

  testWidgets('shows a spinner while loading', (tester) async {
    final answer = Completer<http.Response>();
    routes['GET $_itemPath'] = () => answer.future;
    await withServer(() async {
      await tester.pumpAppInRealZone(page);
      await tester.settleRealZone(
        done: () => requests.any((u) => u.path == _itemPath),
      );
      expect(find.byType(CircularProgressIndicator), findsOneWidget);
      expect(find.text('The Show'), findsOneWidget);

      answer.complete(ok(const {'media': <String, Object>{}}));
      await tester.settleRealZone(done: loaded);
    });
    expect(find.text('No episodes.'), findsOneWidget);
  });

  testWidgets('lists episodes newest first with their progress', (
    tester,
  ) async {
    episodes([
      ('ep_1', 'Ep one', day - 2 * 86400000),
      ('ep_3', 'Ep three', day),
      ('ep_2', 'Ep two', day - 86400000),
    ]);
    routes['GET /api/me'] = () async => ok({
      'mediaProgress': [
        {
          'libraryItemId': 'pod_1',
          'episodeId': 'ep_2',
          'progress': 0.305,
          'isFinished': false,
        },
        {
          'libraryItemId': 'pod_1',
          'episodeId': 'ep_1',
          'progress': 1,
          'isFinished': true,
        },
        // Another podcast's episode with the same id.
        {
          'libraryItemId': 'pod_2',
          'episodeId': 'ep_3',
          'progress': 0.5,
          'isFinished': false,
        },
      ],
    });
    await withServer(() async {
      await tester.pumpAppInRealZone(page);
      await tester.settleRealZone(
        done: () => loaded() && find.textContaining('%').evaluate().isNotEmpty,
      );
    });

    expect(requests.firstWhere((u) => u.path == _itemPath).queryParameters, {
      'expanded': '1',
    });
    expect(titles(), ['Ep three', 'Ep two', 'Ep one']);
    expect(find.textContaining('30%'), findsOneWidget);
    expect(find.textContaining('50%'), findsNothing);
    expect(
      find.byWidgetPredicate((w) => w is Icon && w.semanticLabel == 'Finished'),
      findsOneWidget,
    );
    expect(find.text(_banner), findsNothing);
  });

  testWidgets('the list works without progress', (tester) async {
    episodes([('ep_1', 'Ep one', day)]);
    routes['GET /api/me'] = () async => http.Response('', 500);
    await withServer(() async {
      await tester.pumpAppInRealZone(page);
      await tester.settleRealZone(done: loaded);
    });

    expect(titles(), ['Ep one']);
    expect(find.textContaining('%'), findsNothing);
  });

  testWidgets('says so when the podcast has no episodes', (tester) async {
    episodes([]);
    await withServer(() async {
      await tester.pumpAppInRealZone(page);
      await tester.settleRealZone(done: loaded);
    });

    expect(find.text('No episodes.'), findsOneWidget);
  });

  testWidgets('without a saved list, shows the error and retries on tap', (
    tester,
  ) async {
    routes['GET $_itemPath'] = offline;
    await withServer(() async {
      await tester.pumpAppInRealZone(page);
      await tester.settleRealZone(done: loaded);
      expect(find.text("Can't reach the server."), findsOneWidget);

      episodes([('ep_1', 'Ep one', day)]);
      await tester.tapInRealZone(find.text("Can't reach the server."));
      await tester.settleRealZone(done: () => titles().isNotEmpty);
    });

    expect(titles(), ['Ep one']);
    expect(find.text("Can't reach the server."), findsNothing);
  });

  testWidgets('a 404 shows an error instead of closing', (tester) async {
    routes['GET $_itemPath'] = () async => http.Response('', 404);
    await withServer(() async {
      await tester.pumpAppInRealZone(page);
      await tester.settleRealZone(done: loaded);
    });

    expect(find.byType(EpisodesPage), findsOneWidget);
    expect(find.text('Error loading data'), findsOneWidget);
  });

  testWidgets('offline, shows the saved list with the banner', (tester) async {
    episodes([('ep_1', 'Ep one', day), ('ep_2', 'Ep two', day + 1)]);
    await withServer(() async {
      await tester.pumpAppInRealZone(page);
      await tester.settleRealZone(done: loaded);
      expect(titles(), ['Ep two', 'Ep one']);
      await tester.pumpWidget(const SizedBox());
      // What it saved is on disk before the next visit reads it.
      await tester.runAsync(() => JsonCache.idle);

      routes['GET $_itemPath'] = offline;
      requests.clear();
      await tester.pumpAppInRealZone(page);
      await tester.settleRealZone(
        done: () => find.text(_banner).evaluate().isNotEmpty,
      );
    });

    expect(titles(), ['Ep two', 'Ep one']);
    expect(find.text(_banner), findsOneWidget);
  });

  testWidgets('on 401, closes for the login page', (tester) async {
    routes['GET $_itemPath'] = () async => http.Response('', 401);
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
        done: () => find.byType(EpisodesPage).evaluate().isEmpty,
      );
    });
    await tester.pumpAndSettle();

    expect(
      await tester.runAsync<LibraryResult?>(() => result),
      LibraryResult.sessionExpired,
    );
    expect(find.text('home'), findsOneWidget);
  });
}
