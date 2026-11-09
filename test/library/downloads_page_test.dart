import 'dart:convert';
import 'dart:io';

import 'package:abs_wear/library/view/downloads_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';

import '../helpers/helpers.dart';

const _server = 'http://abs.test';

void main() {
  late Directory root;

  setUp(() {
    root = Directory.systemTemp.createTempSync('abs_downloads_page_test');
    Directory('${root.path}/docs').createSync();
    PathProviderPlatform.instance = FakePathProvider(root.path);
    fakeCrown();
  });

  tearDown(() => root.deleteSync(recursive: true));

  void download(String id, String title, String author, DateTime modified) {
    final dir = Directory('${root.path}/docs/$id')..createSync();
    File('${dir.path}/session.json')
      ..writeAsStringSync(
        jsonEncode({
          'server': id.startsWith('other') ? 'http://other.test' : _server,
          'itemId': id,
          'displayTitle': title,
          'displayAuthor': author,
        }),
      )
      ..setLastModifiedSync(modified);
  }

  const page = DownloadsPage(serverUrl: _server, token: 't', user: 'u');

  bool listed() => find.byType(CircularProgressIndicator).evaluate().isEmpty;

  testWidgets('shows a spinner, then says nothing is downloaded', (
    tester,
  ) async {
    await tester.pumpAppInRealZone(page);
    expect(find.text('Downloads'), findsOneWidget);
    expect(find.byType(CircularProgressIndicator), findsOneWidget);

    await tester.settleRealZone(done: listed);

    expect(find.text('Nothing downloaded.'), findsOneWidget);
  });

  testWidgets("lists this server's downloads, newest first", (tester) async {
    final now = DateTime.now();
    download(
      'li_1',
      'Dune',
      'Frank Herbert',
      now.subtract(const Duration(days: 1)),
    );
    download('li_2', 'Emma', 'Jane Austen', now);
    download('other_1', 'Not mine', 'Someone', now);

    await tester.pumpAppInRealZone(page);
    await tester.settleRealZone(done: listed);

    expect(find.text('Nothing downloaded.'), findsNothing);
    expect(find.text('Not mine'), findsNothing);
    expect(find.text('Frank Herbert'), findsOneWidget);
    final emma = tester.getTopLeft(find.text('Emma'));
    final dune = tester.getTopLeft(find.text('Dune'));
    expect(emma.dy, lessThan(dune.dy));
  });
}
