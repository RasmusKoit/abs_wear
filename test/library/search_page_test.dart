import 'dart:convert';

import 'package:abs_wear/library/data/library_api.dart';
import 'package:abs_wear/library/view/search_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import '../helpers/helpers.dart';

void main() {
  late List<Uri> requests;
  late http.Response Function(Uri url) answer;
  late http.Client client;

  setUp(() {
    fakeCrown();
    requests = [];
    client = MockClient((request) async {
      if (request.url.path.endsWith('/cover')) return http.Response('', 404);
      requests.add(request.url);
      return answer(request.url);
    });
  });

  Map<String, Object> item(String id, String title) => {
    'libraryItem': {
      'id': id,
      'mediaType': 'book',
      'media': {
        'metadata': {'title': title, 'authorName': 'Someone'},
      },
    },
  };

  const page = SearchPage(
    serverUrl: 'http://abs.test',
    token: 't',
    libraryId: 'lib1',
    user: 'u',
  );

  Future<void> search(WidgetTester tester, String text) async {
    await tester.runAsync(() async {
      await tester.enterText(find.byType(TextField), text);
      await tester.testTextInput.receiveAction(TextInputAction.search);
      await tester.pump();
    });
    await tester.settleRealZone(done: () => requests.isNotEmpty);
  }

  testWidgets('searches the library and lists the matches', (tester) async {
    answer = (_) => http.Response(
      jsonEncode({
        'book': [item('li_1', 'Dune'), item('li_2', 'Dune Messiah')],
        'authors': <Object>[],
      }),
      200,
    );

    await http.runWithClient(() async {
      await tester.pumpAppInRealZone(page);
      await search(tester, ' dune & co ');
    }, () => client);

    final url = requests.single;
    expect(url.path, '/api/libraries/lib1/search');
    expect(url.queryParameters, {'q': 'dune & co', 'limit': '25'});
    expect(find.text('Dune'), findsOneWidget);
    expect(find.text('Dune Messiah'), findsOneWidget);
  });

  testWidgets('says so when nothing matches', (tester) async {
    answer = (_) => http.Response(jsonEncode({'book': <Object>[]}), 200);

    await http.runWithClient(() async {
      await tester.pumpAppInRealZone(page);
      await search(tester, 'zzz');
    }, () => client);

    expect(find.text('No matches.'), findsOneWidget);
  });

  testWidgets('an empty query asks nothing', (tester) async {
    answer = (_) => http.Response('{}', 200);

    await http.runWithClient(() async {
      await tester.pumpAppInRealZone(page);
      await search(tester, '   ');
    }, () => client);

    expect(requests, isEmpty);
  });

  testWidgets('a failed search shows the error and retries on tap', (
    tester,
  ) async {
    answer = (_) => http.Response('', 500);

    await http.runWithClient(() async {
      await tester.pumpAppInRealZone(page);
      await search(tester, 'dune');
      expect(find.text('Error loading data'), findsOneWidget);

      answer = (_) => http.Response(
        jsonEncode({
          'book': [item('li_1', 'Dune')],
        }),
        200,
      );
      requests.clear();
      await tester.tapInRealZone(find.text('Error loading data'));
      await tester.settleRealZone(done: () => requests.isNotEmpty);
    }, () => client);

    expect(find.text('Dune'), findsOneWidget);
  });

  group('searchLibrary', () {
    test('reads podcast matches too, and skips repeats', () async {
      answer = (_) => http.Response(
        jsonEncode({
          'podcast': [
            {
              'libraryItem': {
                'id': 'pod_1',
                'mediaType': 'podcast',
                'media': {
                  'metadata': {'title': 'The Show', 'author': 'Host'},
                },
              },
            },
          ],
          'episodes': [item('pod_1', 'ignored')],
        }),
        200,
      );

      final results = await http.runWithClient(
        () => searchLibrary('http://abs.test', 't', 'lib1', 'show'),
        () => client,
      );

      expect(results.single.id, 'pod_1');
      expect(results.single.isPodcast, isTrue);
      expect(results.single.author, 'Host');
    });
  });
}
