import 'dart:convert';
import 'dart:io';

import 'package:abs_wear/library/data/downloads.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';

import '../helpers/helpers.dart';

const _server = 'http://abs.test';

void main() {
  late Directory root;
  late Directory docs;

  setUp(() {
    root = Directory.systemTemp.createTempSync('abs_downloads_test');
    docs = Directory('${root.path}/docs')..createSync();
    PathProviderPlatform.instance = FakePathProvider(root.path);
  });

  tearDown(() => root.deleteSync(recursive: true));

  /// A download folder with the session details the player saves.
  Directory download(
    String folder,
    Map<String, Object?> session, {
    DateTime? modified,
    bool cover = false,
  }) {
    final dir = Directory('${docs.path}/$folder')..createSync();
    final meta = File('${dir.path}/session.json')
      ..writeAsStringSync(jsonEncode(session));
    if (modified != null) meta.setLastModifiedSync(modified);
    if (cover) File('${dir.path}/cover.jpg').writeAsBytesSync([0xff, 0xd8]);
    return dir;
  }

  test('nothing downloaded lists nothing', () async {
    expect(await listDownloads(_server), isEmpty);
  });

  test('no documents directory lists nothing', () async {
    docs.deleteSync(recursive: true);
    expect(await listDownloads(_server), isEmpty);
  });

  test('lists a book with its saved title, author and cover', () async {
    download('li_1', {
      'server': _server,
      'itemId': 'li_1',
      'displayTitle': 'Dune',
      'displayAuthor': 'Frank Herbert',
    }, cover: true);

    final item = (await listDownloads(_server)).single;

    expect(item.itemId, 'li_1');
    expect(item.episodeId, isNull);
    expect(item.title, 'Dune');
    expect(item.author, 'Frank Herbert');
    expect(item.coverFile?.readAsBytesSync(), [0xff, 0xd8]);
  });

  test('lists a podcast episode with its episode id', () async {
    download('pod_1_ep_1', {
      'server': _server,
      'itemId': 'pod_1',
      'episodeId': 'ep_1',
      'displayTitle': 'Episode 1',
    });

    final item = (await listDownloads(_server)).single;

    expect(item.itemId, 'pod_1');
    expect(item.episodeId, 'ep_1');
    expect(item.coverFile, isNull);
  });

  test('falls back to the media title, then to no title', () async {
    final now = DateTime.now();
    download('a', {
      'server': _server,
      'itemId': 'a',
      'mediaMetadata': {'title': 'From metadata'},
    }, modified: now);
    download('b', {
      'server': _server,
      'itemId': 'b',
    }, modified: now.subtract(const Duration(minutes: 1)));

    final items = await listDownloads(_server);

    expect([for (final i in items) i.title], ['From metadata', '']);
    expect(items.every((i) => i.author.isEmpty), isTrue);
  });

  test('leaves out other servers, old and broken downloads', () async {
    download('mine', {'server': _server, 'itemId': 'mine'});
    download('other', {'server': 'http://other.test', 'itemId': 'other'});
    // From before the server and item were recorded.
    download('old', {
      'mediaMetadata': {'title': 'Old'},
    });
    download('no_item', {'server': _server});
    Directory('${docs.path}/no_meta').createSync();
    Directory('${docs.path}/broken').createSync();
    File('${docs.path}/broken/session.json').writeAsStringSync('{"server');
    File('${docs.path}/stray.txt').writeAsStringSync('not a folder');

    final items = await listDownloads(_server);

    expect([for (final i in items) i.itemId], ['mine']);
  });

  test('lists the newest download first', () async {
    final now = DateTime.now();
    download('older', {
      'server': _server,
      'itemId': 'older',
    }, modified: now.subtract(const Duration(days: 2)));
    download('newest', {'server': _server, 'itemId': 'newest'}, modified: now);
    download('middle', {
      'server': _server,
      'itemId': 'middle',
    }, modified: now.subtract(const Duration(days: 1)));

    final items = await listDownloads(_server);

    expect([for (final i in items) i.itemId], ['newest', 'middle', 'older']);
  });
}
