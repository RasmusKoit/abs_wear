import 'dart:convert';
import 'dart:io';
import 'dart:ui' show Tristate;

import 'package:abs_wear/ambient_mode/ambient_mode.dart';
import 'package:abs_wear/library/data/library_api.dart';
import 'package:abs_wear/library/view/downloads_page.dart';
import 'package:abs_wear/library/view/episodes_page.dart';
import 'package:abs_wear/library/view/libraries_page.dart';
import 'package:abs_wear/library/view/library_page.dart';
import 'package:abs_wear/player/darts/audio_player.dart';
import 'package:abs_wear/player/view/controls_view.dart';
import 'package:abs_wear/player/view/player_view.dart';
import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';

import '../helpers/helpers.dart';

const _server = 'http://abs.test';
const _volumeEvents = EventChannel(
  'com.kurenai7968.volume_controller.volume_listener_event',
);

/// What a screen reader announces on the main screens: labels for icons
/// and spinners, durations in words, one node per tappable row, and
/// decorative covers left out.
void main() {
  late Directory root;
  late Map<String, http.Response Function()> routes;
  late http.Client client;

  setUp(() {
    root = Directory.systemTemp.createTempSync('abs_semantics_test');
    Directory('${root.path}/docs').createSync();
    PathProviderPlatform.instance = FakePathProvider(root.path);
    fakeCrown();
    routes = {};
    client = MockClient((request) async {
      final key = '${request.method} ${request.url.path}';
      return routes[key]?.call() ?? http.Response('', 404);
    });
  });

  tearDown(() => root.deleteSync(recursive: true));

  http.Response ok(Object body) => http.Response(jsonEncode(body), 200);

  /// A widget test with semantics on, released before the framework's
  /// end-of-test checks (which fail on a live handle).
  void semanticsTest(String name, Future<void> Function(WidgetTester) body) {
    testWidgets(name, (tester) async {
      final semantics = tester.ensureSemantics();
      try {
        await body(tester);
      } finally {
        semantics.dispose();
      }
    });
  }

  AudioPlayerController loaded() => AudioPlayerController()
    ..isLoaded = true
    ..bookTitle = 'Dune'
    ..duration = 36000
    ..chapters = const [BookChapter(start: 0, end: 4000, title: 'One')];

  group('player', () {
    semanticsTest('labels every button and reads the time left in words', (
      tester,
    ) async {
      await tester.pumpWidget(
        watchApp(Scaffold(body: PlayerViewPage(playerController: loaded()))),
      );
      await tester.pump();

      for (final label in [
        'Previous chapter',
        // Paused: the button offers to play.
        'Play',
        'Next chapter',
        'Back 10 seconds',
        'Forward 10 seconds',
      ]) {
        expect(
          find.semantics.byPredicate(
            (node) =>
                node.tooltip == label &&
                node.getSemanticsData().hasAction(SemanticsAction.tap),
          ),
          findsOne,
          reason: label,
        );
      }
      expect(find.text('01:06:40'), findsOneWidget);
      expect(
        find.bySemanticsLabel('1 hour 6 minutes left in chapter'),
        findsOneWidget,
      );
      expect(find.bySemanticsLabel('Dune'), findsOneWidget);
      expect(find.bySemanticsLabel('One'), findsOneWidget);
    });

    semanticsTest('always-on reads the minutes in words', (tester) async {
      AmbientModeListener.instance.value = true;
      addTearDown(() => AmbientModeListener.instance.value = false);
      await tester.pumpWidget(
        watchApp(Scaffold(body: PlayerViewPage(playerController: loaded()))),
      );
      await tester.pump();

      expect(find.text('01:06'), findsOneWidget);
      expect(
        find.bySemanticsLabel('1 hour 6 minutes left in chapter'),
        findsOneWidget,
      );
    });

    semanticsTest('a loading session is announced', (tester) async {
      await tester.pumpWidget(
        watchApp(
          Scaffold(
            body: PlayerViewPage(playerController: loaded()..isLoaded = false),
          ),
        ),
      );

      expect(find.bySemanticsLabel('Loading'), findsOneWidget);
    });

    semanticsTest('controls read the volume and sleep timer in words', (
      tester,
    ) async {
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            ..setMockStreamHandler(
              _volumeEvents,
              MockStreamHandler.inline(onListen: (_, sink) => sink.success(.7)),
            );
      addTearDown(() => messenger.setMockStreamHandler(_volumeEvents, null));
      final controller = loaded();
      await tester.runAsync(
        () => tester.pumpWidget(
          watchApp(ControlViewPage(playerController: controller)),
        ),
      );
      await tester.pump();

      expect(find.text('70%'), findsOneWidget);
      expect(find.bySemanticsLabel('Volume 70%'), findsOneWidget);
      for (final label in ['Volume down', 'Volume up', 'Slower', 'Faster']) {
        expect(find.byTooltip(label), findsOneWidget, reason: label);
      }
      expect(
        find.bySemanticsLabel(RegExp(r'Sleep timer\s+Off')),
        findsOneWidget,
      );

      controller.cycleSleepTimer();
      await tester.pump();
      expect(find.text('15:00'), findsOneWidget);
      expect(
        find.bySemanticsLabel(RegExp(r'Sleep timer\s+15 minutes')),
        findsOneWidget,
      );
      controller.setSleepTimer(null);
      // Closed while the volume channel is still answered.
      await tester.pumpWidget(const SizedBox());
    });
  });

  group('library', () {
    semanticsTest('a Continue Listening card is one tappable item, without '
        'its cover', (tester) async {
      routes['GET /api/libraries/lib1/personalized'] = () => ok([
        {
          'id': 'continue-listening',
          'entities': [
            {
              'id': 'li_1',
              'mediaType': 'book',
              'media': {
                'metadata': {'title': 'Dune', 'authorName': 'Frank Herbert'},
              },
            },
          ],
        },
      ]);
      await http.runWithClient(() async {
        await tester.runAsync(
          () => tester.pumpWidget(
            watchApp(
              const LibraryPage(
                token: 't',
                serverUrl: _server,
                libraryId: 'lib1',
                user: 'u',
              ),
            ),
          ),
        );
        await tester.settleRealZone(
          done: () => find.text('Dune').evaluate().isNotEmpty,
        );
      }, () => client);

      final card = tester.getSemantics(find.text('Dune'));
      expect(card.label, 'Dune\nFrank Herbert');
      expect(card.getSemanticsData().hasAction(SemanticsAction.tap), isTrue);
      expect(
        find.semantics.byPredicate(
          (node) => node.getSemanticsData().flagsCollection.isImage,
        ),
        findsNothing,
        reason: 'covers are decorative',
      );
    });

    semanticsTest('the current library is marked selected', (tester) async {
      await tester.pumpWidget(
        watchApp(
          const LibrariesPage(
            libraries: [
              LibraryInfo(id: 'lib1', name: 'Audiobooks', isPodcast: false),
              LibraryInfo(id: 'lib2', name: 'Podcasts', isPodcast: true),
            ],
            currentId: 'lib2',
          ),
        ),
      );

      bool selected(String name) =>
          tester
              .getSemantics(find.text(name))
              .getSemanticsData()
              .flagsCollection
              .isSelected ==
          Tristate.isTrue;
      expect(selected('Podcasts'), isTrue);
      expect(selected('Audiobooks'), isFalse);
    });

    semanticsTest('episode rows read their date, progress and finished state', (
      tester,
    ) async {
      final day = DateTime(2026, 11, 8).millisecondsSinceEpoch;
      routes['GET /api/items/pod_1'] = () => ok({
        'id': 'pod_1',
        'media': {
          'episodes': [
            {'id': 'ep_1', 'title': 'Started', 'publishedAt': day},
            {'id': 'ep_2', 'title': 'Done', 'publishedAt': day - 1},
          ],
        },
      });
      routes['GET /api/me'] = () => ok({
        'mediaProgress': [
          {
            'libraryItemId': 'pod_1',
            'episodeId': 'ep_1',
            'progress': 0.3,
            'isFinished': false,
          },
          {
            'libraryItemId': 'pod_1',
            'episodeId': 'ep_2',
            'progress': 1,
            'isFinished': true,
          },
        ],
      });
      await http.runWithClient(() async {
        await tester.runAsync(
          () => tester.pumpWidget(
            watchApp(
              const EpisodesPage(
                serverUrl: _server,
                token: 't',
                user: 'u',
                podcast: ShelfBook(
                  id: 'pod_1',
                  title: 'The Show',
                  author: 'Host',
                  isPodcast: true,
                ),
              ),
            ),
          ),
        );
        await tester.settleRealZone(
          done: () => find.textContaining('30%').evaluate().isNotEmpty,
        );
      }, () => client);

      final started = tester.getSemantics(find.text('Started'));
      expect(started.label, 'Started\nNov 8, 2026, 30%');
      expect(started.getSemanticsData().hasAction(SemanticsAction.tap), isTrue);
      expect(
        tester.getSemantics(find.text('Done')).label,
        allOf(startsWith('Done\n'), endsWith('Finished')),
      );
    });

    semanticsTest('a loading list is announced', (tester) async {
      await tester.runAsync(
        () => tester.pumpWidget(
          watchApp(
            const DownloadsPage(serverUrl: _server, token: 't', user: 'u'),
          ),
        ),
      );

      expect(find.bySemanticsLabel('Loading'), findsOneWidget);
      await tester.settleRealZone(
        done: () => find.text('Nothing downloaded.').evaluate().isNotEmpty,
      );
    });
  });
}
