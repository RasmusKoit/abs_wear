import 'dart:async';
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
}
