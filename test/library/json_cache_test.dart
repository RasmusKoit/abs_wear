import 'dart:io';

import 'package:abs_wear/library/data/json_cache.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';

import '../helpers/helpers.dart';

void main() {
  late Directory root;

  Directory cacheDir() => Directory('${root.path}/support/json_cache');

  setUp(() {
    root = Directory.systemTemp.createTempSync('abs_json_cache_test');
    PathProviderPlatform.instance = FakePathProvider(root.path);
  });

  tearDown(() => root.deleteSync(recursive: true));

  test('a missing key reads as null', () async {
    expect(await JsonCache.read('shelf_1'), isNull);
  });

  test('a written value reads back', () async {
    await JsonCache.write('shelf_1', [
      {'i': 'li_1', 't': 'Dune'},
    ]);

    expect(await JsonCache.read('shelf_1'), [
      {'i': 'li_1', 't': 'Dune'},
    ]);
    expect(await JsonCache.read('shelf_2'), isNull);
  });

  test('a write replaces the value and leaves no temp file', () async {
    await JsonCache.write('k', {'total': 1});
    await JsonCache.write('k', {'total': 2});

    expect(await JsonCache.read('k'), {'total': 2});
    final names = [
      for (final f in cacheDir().listSync()) f.uri.pathSegments.last,
    ];
    expect(names.where((n) => n.endsWith('.tmp')), isEmpty);
  });

  test('writes to one key land in the order they were made', () async {
    final writes = [
      for (var i = 0; i < 20; i++) JsonCache.write('k', {'n': i}),
    ];
    await Future.wait(writes);

    expect(await JsonCache.read('k'), {'n': 19});
  });

  test('keys with path characters stay inside the cache', () async {
    await JsonCache.write('../../escape|key', 'v');

    expect(await JsonCache.read('../../escape|key'), 'v');
    expect(cacheDir().listSync(), hasLength(1));
    expect(Directory('${root.path}/support').listSync(), hasLength(1));
  });

  test('an unreadable file reads as null', () async {
    await JsonCache.write('k', {'ok': true});
    for (final f in cacheDir().listSync().whereType<File>()) {
      f.writeAsStringSync('{"truncated');
    }

    expect(await JsonCache.read('k'), isNull);
  });

  test("a failed write doesn't throw", () async {
    // The cache directory can't be created: a file is in the way.
    Directory('${root.path}/support').createSync();
    File(cacheDir().path).writeAsStringSync('');

    await JsonCache.write('k', 1);

    expect(await JsonCache.read('k'), isNull);
  });

  test('clear removes everything', () async {
    await JsonCache.write('a', 1);
    await JsonCache.write('b', 2);

    await JsonCache.clear();

    expect(await JsonCache.read('a'), isNull);
    expect(await JsonCache.read('b'), isNull);
    expect(cacheDir().existsSync(), isFalse);
    // Clearing again (nothing there) is fine, and the cache still works.
    await JsonCache.clear();
    await JsonCache.write('a', 3);
    expect(await JsonCache.read('a'), 3);
  });
}
