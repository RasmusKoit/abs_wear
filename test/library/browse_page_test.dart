import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:abs_wear/library/data/json_cache.dart';
import 'package:abs_wear/library/view/browse_page.dart';
import 'package:abs_wear/library/view/search_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:plugin_platform_interface/plugin_platform_interface.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../helpers/helpers.dart';

/// Answers the support directory (the cache read) only when told to.
class _SlowPathProvider extends PathProviderPlatform
    with MockPlatformInterfaceMixin {
  _SlowPathProvider(this.path);
  final String path;
  final support = Completer<String?>();

  @override
  Future<String?> getApplicationSupportPath() => support.future;
}

void main() {
  testWidgets('leaving before the cached list loads does not throw', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({});
    final root = Directory.systemTemp.createTempSync('abs_browse_test');
    addTearDown(() => root.deleteSync(recursive: true));
    final paths = _SlowPathProvider(root.path);
    PathProviderPlatform.instance = paths;
    final requests = <String>[];
    final client = MockClient((request) async {
      requests.add(request.url.path);
      return http.Response('', 404);
    });

    await http.runWithClient(() async {
      await tester.pumpApp(
        const BrowsePage(
          serverUrl: 'http://abs.test',
          token: 't',
          libraryId: 'lib1',
          user: 'u',
        ),
      );
      // The user leaves while the cache is still being read.
      await tester.pumpWidget(const SizedBox());
      paths.support.complete(root.path);
      await tester.pumpAndSettle();
    }, () => client);

    expect(tester.takeException(), isNull);
    expect(requests, isEmpty, reason: 'nothing to load for a closed page');
  });

  group('paging', () {
    late Directory root;
    late List<Uri> requests;
    late int total;
    late http.Client client;

    /// Books 000..total-1, A to Z, 30 to a page.
    setUp(() {
      root = Directory.systemTemp.createTempSync('abs_browse_paging_test');
      PathProviderPlatform.instance = FakePathProvider(root.path);
      SharedPreferences.setMockInitialValues({});
      fakeCrown();
      requests = [];
      total = 45;
      client = MockClient((request) async {
        // Covers: none, so only list pages are counted.
        if (request.url.path.endsWith('/cover')) return http.Response('', 404);
        requests.add(request.url);
        final query = request.url.queryParameters;
        final limit = int.parse(query['limit']!);
        final page = int.parse(query['page']!);
        // Newest first: other titles, so the two lists can be told apart.
        final prefix = query['sort'] == 'addedAt' ? 'New' : 'Book';
        final ids = [
          for (var i = page * limit; i < total && i < (page + 1) * limit; i++)
            i.toString().padLeft(3, '0'),
        ];
        return http.Response(
          jsonEncode({
            'total': total,
            'results': [
              for (final id in ids)
                {
                  'id': 'li_$id',
                  'mediaType': 'book',
                  'media': {
                    'metadata': {'title': '$prefix $id', 'authorName': 'A'},
                  },
                },
            ],
          }),
          200,
        );
      });
    });

    tearDown(() async {
      await JsonCache.idle;
      root.deleteSync(recursive: true);
    });

    const page = BrowsePage(
      serverUrl: 'http://abs.test',
      token: 't',
      libraryId: 'lib1',
      user: 'u',
    );

    List<int> pagesAsked() => [
      for (final u in requests) int.parse(u.queryParameters['page']!),
    ];

    Future<void> scrollToEnd(WidgetTester tester) async {
      for (var i = 0; i < 6; i++) {
        await tester.dragInRealZone(
          find.byType(ListView),
          const Offset(0, -600),
        );
        await tester.settleRealZone();
      }
    }

    /// Closes the page in the real zone, so its cache write finishes.
    Future<void> leave(WidgetTester tester) async {
      await tester.runAsync(() => tester.pumpWidget(const SizedBox()));
      await tester.runAsync(() => JsonCache.idle);
    }

    testWidgets('loads the next page as the list scrolls', (tester) async {
      await http.runWithClient(() async {
        await tester.pumpAppInRealZone(page);
        await tester.settleRealZone(done: () => requests.isNotEmpty);

        expect(find.text('45 books'), findsOneWidget);
        expect(pagesAsked(), [0], reason: 'the end is not in view yet');
        final first = requests.single;
        expect(first.path, '/api/libraries/lib1/items');
        expect(first.queryParameters, {
          'limit': '30',
          'page': '0',
          'sort': 'media.metadata.title',
          'minified': '1',
        });

        await scrollToEnd(tester);
      }, () => client);

      expect(pagesAsked(), [0, 1], reason: 'nothing after the last page');
      expect(find.text('Book 044'), findsOneWidget);
      await leave(tester);
    });

    testWidgets('a revisit continues after the saved books', (tester) async {
      await http.runWithClient(() async {
        await tester.pumpAppInRealZone(page);
        await tester.settleRealZone(done: () => requests.isNotEmpty);
        await scrollToEnd(tester);
        // What it saved is on disk before the revisit reads it.
        await leave(tester);

        // The first page is unchanged: the saved 45 books are kept and
        // nothing more is fetched.
        requests.clear();
        await tester.pumpAppInRealZone(page);
        await tester.settleRealZone(done: () => requests.isNotEmpty);
        await scrollToEnd(tester);
      }, () => client);

      expect(pagesAsked(), [0]);
      expect(find.text('Book 044'), findsOneWidget);
      await leave(tester);
    });

    testWidgets('a changed library starts the list over', (tester) async {
      await http.runWithClient(() async {
        await tester.pumpAppInRealZone(page);
        await tester.settleRealZone(done: () => requests.isNotEmpty);
        await scrollToEnd(tester);
        // What it saved is on disk before the revisit reads it.
        await leave(tester);

        // Books were removed since: the saved list is replaced.
        total = 3;
        requests.clear();
        await tester.pumpAppInRealZone(page);
        await tester.settleRealZone(done: () => requests.isNotEmpty);
      }, () => client);

      expect(find.text('3 books'), findsOneWidget);
      expect(find.text('Book 002'), findsOneWidget);
      expect(find.text('Book 003'), findsNothing);
      await leave(tester);
    });

    String cacheKey(String suffix) =>
        'browse_${'http://abs.test|u'.hashCode}_lib1$suffix';

    Future<String?> firstCached(WidgetTester tester, String suffix) async {
      final cached = await tester.runAsync(
        () => JsonCache.read(cacheKey(suffix)),
      );
      final books = (cached as Map<String, dynamic>?)?['books'] as List?;
      return (books?.first as Map<String, dynamic>?)?['t'] as String?;
    }

    testWidgets('the sort toggle switches to newest first and is remembered', (
      tester,
    ) async {
      await http.runWithClient(() async {
        await tester.pumpAppInRealZone(page);
        await tester.settleRealZone(done: () => requests.isNotEmpty);
        expect(find.text('By title'), findsOneWidget);

        requests.clear();
        await tester.tapInRealZone(find.text('By title'));
        await tester.settleRealZone(done: () => requests.isNotEmpty);

        expect(find.text('Newest first'), findsOneWidget);
        expect(find.text('New 000'), findsOneWidget);
        expect(find.text('Book 000'), findsNothing);
        expect(requests.single.queryParameters, {
          'limit': '30',
          'page': '0',
          'sort': 'addedAt',
          'desc': '1',
          'minified': '1',
        });
        final prefs = await tester.runAsync(SharedPreferences.getInstance);
        expect(prefs!.getString('browseSort'), 'added');

        // A revisit opens with the remembered sort.
        await leave(tester);
        requests.clear();
        await tester.pumpAppInRealZone(page);
        await tester.settleRealZone(done: () => requests.isNotEmpty);
      }, () => client);

      expect(find.text('Newest first'), findsOneWidget);
      expect(requests.first.queryParameters['sort'], 'addedAt');
      await leave(tester);
    });

    testWidgets('each sort is saved under its own key, once on leaving', (
      tester,
    ) async {
      await http.runWithClient(() async {
        await tester.pumpAppInRealZone(page);
        await tester.settleRealZone(done: () => requests.isNotEmpty);
        await scrollToEnd(tester);
        await tester.runAsync(() => JsonCache.idle);
        // Still on the page: nothing written yet.
        expect(await firstCached(tester, ''), isNull);

        // Switching sorts (at the top of the list) saves the list it leaves.
        for (var i = 0; i < 3; i++) {
          await tester.dragInRealZone(
            find.byType(ListView),
            const Offset(0, 1200),
          );
        }
        await tester.settleRealZone();
        requests.clear();
        await tester.tapInRealZone(find.text('By title'));
        await tester.settleRealZone(done: () => requests.isNotEmpty);
        await tester.runAsync(() => JsonCache.idle);
        expect(await firstCached(tester, ''), 'Book 000');

        await leave(tester);
      }, () => client);

      expect(await firstCached(tester, ''), 'Book 000');
      expect(await firstCached(tester, '_added'), 'New 000');
    });

    testWidgets('a list left open is saved once it stops growing', (
      tester,
    ) async {
      browseSaveDelay = const Duration(seconds: 2);
      addTearDown(() => browseSaveDelay = const Duration(seconds: 5));
      Future<int?> cachedCount() async {
        final cached = await tester.runAsync(
          () => JsonCache.read(cacheKey('')),
        );
        return ((cached as Map<String, dynamic>?)?['books'] as List?)?.length;
      }

      Future<void> idle() => tester.runAsync(() async {
        await Future<void>.delayed(const Duration(milliseconds: 2300));
        await JsonCache.idle;
      });

      await http.runWithClient(() async {
        await tester.pumpAppInRealZone(page);
        await tester.settleRealZone(done: () => requests.isNotEmpty);
        expect(await cachedCount(), isNull, reason: 'not idle long enough');
        await idle();
        expect(await cachedCount(), 30);

        // The next page restarts the wait, then is saved too.
        await scrollToEnd(tester);
        expect(pagesAsked(), [0, 1]);
        expect(await cachedCount(), 30);
        await idle();
        expect(await cachedCount(), 45);
      }, () => client);
      await leave(tester);
    });

    testWidgets('the search button opens search', (tester) async {
      await http.runWithClient(() async {
        await tester.pumpAppInRealZone(page);
        await tester.settleRealZone(done: () => requests.isNotEmpty);
        await tester.tapInRealZone(find.byTooltip('Search'));
        await tester.settleRealZone();
      }, () => client);

      expect(find.byType(SearchPage), findsOneWidget);
      await leave(tester);
    });
  });
}
