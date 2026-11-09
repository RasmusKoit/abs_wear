import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:abs_wear/library/view/browse_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:plugin_platform_interface/plugin_platform_interface.dart';

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
      fakeCrown();
      requests = [];
      total = 45;
      client = MockClient((request) async {
        requests.add(request.url);
        final query = request.url.queryParameters;
        final limit = int.parse(query['limit']!);
        final page = int.parse(query['page']!);
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
                    'metadata': {'title': 'Book $id', 'authorName': 'A'},
                  },
                },
            ],
          }),
          200,
        );
      });
    });

    tearDown(() => root.deleteSync(recursive: true));

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
    });

    testWidgets('a revisit continues after the saved books', (tester) async {
      await http.runWithClient(() async {
        await tester.pumpAppInRealZone(page);
        await tester.settleRealZone(done: () => requests.isNotEmpty);
        await scrollToEnd(tester);
        await tester.pumpWidget(const SizedBox());

        // The first page is unchanged: the saved 45 books are kept and
        // nothing more is fetched.
        requests.clear();
        await tester.pumpAppInRealZone(page);
        await tester.settleRealZone(done: () => requests.isNotEmpty);
        await scrollToEnd(tester);
      }, () => client);

      expect(pagesAsked(), [0]);
      expect(find.text('Book 044'), findsOneWidget);
    });

    testWidgets('a changed library starts the list over', (tester) async {
      await http.runWithClient(() async {
        await tester.pumpAppInRealZone(page);
        await tester.settleRealZone(done: () => requests.isNotEmpty);
        await scrollToEnd(tester);
        await tester.pumpWidget(const SizedBox());

        // Books were removed since: the saved list is replaced.
        total = 3;
        requests.clear();
        await tester.pumpAppInRealZone(page);
        await tester.settleRealZone(done: () => requests.isNotEmpty);
      }, () => client);

      expect(find.text('3 books'), findsOneWidget);
      expect(find.text('Book 002'), findsOneWidget);
      expect(find.text('Book 003'), findsNothing);
    });
  });
}
