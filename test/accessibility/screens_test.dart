import 'dart:convert';
import 'dart:io';

import 'package:abs_wear/ambient_mode/ambient_mode.dart';
import 'package:abs_wear/app/view/app.dart';
import 'package:abs_wear/library/data/json_cache.dart';
import 'package:abs_wear/library/data/library_api.dart';
import 'package:abs_wear/library/view/browse_page.dart';
import 'package:abs_wear/library/view/downloads_page.dart';
import 'package:abs_wear/library/view/episodes_page.dart';
import 'package:abs_wear/library/view/libraries_page.dart';
import 'package:abs_wear/library/view/library_page.dart';
import 'package:abs_wear/login/view/login_page.dart';
import 'package:abs_wear/player/darts/audio_player.dart';
import 'package:abs_wear/player/view/controls_view.dart';
import 'package:abs_wear/player/view/player_view.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../helpers/helpers.dart';

const _server = 'http://abs.test';

// Long enough to need ellipsizing or wrapping on a watch.
const _bookTitle = 'The Fellowship of the Ring: Being the First Part';
const _author = 'J. R. R. Tolkien and a long list of narrators';

/// Every main screen against Android's accessibility guidelines (tap
/// targets, labels, contrast) on a 454 px round watch, at the default and
/// large text sizes, with bold text, and in long and right-to-left
/// languages: nothing may overflow, and the player's controls must stay on
/// the round screen.
void main() {
  late Directory root;
  late Map<String, http.Response Function()> routes;
  late http.Client client;

  setUp(() {
    root = Directory.systemTemp.createTempSync('abs_a11y_test');
    Directory('${root.path}/docs').createSync();
    PathProviderPlatform.instance = FakePathProvider(root.path);
    fakeCrown();
    routes = {};
    client = MockClient((request) async {
      final key = '${request.method} ${request.url.path}';
      return routes[key]?.call() ?? http.Response('', 404);
    });
  });

  tearDown(() async {
    // A page's cache write may still be running in that directory.
    await JsonCache.idle;
    root.deleteSync(recursive: true);
  });

  http.Response ok(Object body) => http.Response(jsonEncode(body), 200);

  Map<String, Object> book(String id, String title, String author) => {
    'id': id,
    'mediaType': 'book',
    'media': {
      'metadata': {'title': title, 'authorName': author},
    },
  };

  /// The variants each screen is checked in.
  final variants = <({String name, double scale, bool bold, Locale? locale})>[
    for (final scale in watchTextScales)
      (name: 'text x$scale', scale: scale, bold: false, locale: null),
    (name: 'bold text x1.3', scale: 1.3, bold: true, locale: null),
    (name: 'Russian x1.3', scale: 1.3, bold: false, locale: const Locale('ru')),
    (name: 'Arabic x1.3', scale: 1.3, bold: false, locale: const Locale('ar')),
  ];

  /// Runs [body] once per variant, with [pump] showing a screen in it.
  void screen(
    String name,
    Future<void> Function(WidgetTester tester, Widget Function(Widget home) app)
    body,
  ) {
    group(name, () {
      for (final v in variants) {
        testWidgets(v.name, (tester) async {
          useWatchScreen(tester);
          await body(
            tester,
            (home) => watchApp(
              home,
              textScale: v.scale,
              boldText: v.bold,
              locale: v.locale,
            ),
          );
          expectNoLayoutErrors(tester);
        });
      }
    });
  }

  group('login', () {
    screen('server', (tester, app) async {
      SharedPreferences.setMockInitialValues({});
      await tester.pumpWidget(app(const LoginPage()));
      await tester.pumpAndSettle();
      expect(find.byType(TextFormField), findsOneWidget);
      expect(find.byType(ElevatedButton), findsOneWidget); // Next
      await expectAccessible(tester);
      expectNoLayoutErrors(tester);
    });

    /// Enters the server and taps "Next".
    Future<void> next(
      WidgetTester tester,
      Widget Function(Widget home) app,
    ) async {
      SharedPreferences.setMockInitialValues({});
      await tester.pumpWidget(app(const LoginPage()));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextFormField).first, fakeAbsUrl);
      // Done typing: the keyboard closes (or the field keeps itself in view).
      FocusManager.instance.primaryFocus?.unfocus();
      await tester.pumpAndSettle();
      await tester.tap(find.byType(ElevatedButton));
      await tester.pumpAndSettle();
    }

    screen('choice, then the password form', (tester, app) async {
      await http.runWithClient(() async {
        await next(tester, app);
        expect(find.byType(ElevatedButton), findsNWidgets(2));
        expectNoLayoutErrors(tester);
        await expectAccessible(tester);
        // Password login: username and password, then Login.
        await tester.tap(find.byType(ElevatedButton).first);
        await tester.pumpAndSettle();
        expect(find.byType(TextFormField), findsNWidgets(2));
        expectNoLayoutErrors(tester);
        await expectAccessible(tester);
      }, () => FakeServers().client);
    });

    /// Enters the server and chooses SSO.
    Future<void> startSso(
      WidgetTester tester,
      Widget Function(Widget home) app,
    ) async {
      await next(tester, app);
      // The second choice is SSO.
      await tester.drag(find.byType(ListView), const Offset(0, -400));
      await tester.pumpAndSettle();
      await tester.tap(find.byType(ElevatedButton).last);
      await tester.pumpAndSettle();
    }

    Future<void> submit(WidgetTester tester, String text) async {
      await tester.enterText(find.byType(TextFormField).first, text);
      FocusManager.instance.primaryFocus?.unfocus();
      await tester.pumpAndSettle();
      await tester.drag(find.byType(ListView), const Offset(0, -400));
      await tester.pumpAndSettle();
      await tester.tap(find.byType(ElevatedButton));
      await tester.pumpAndSettle();
    }

    screen('SSO password and consent', (tester, app) async {
      await http.runWithClient(() async {
        await startSso(tester, app);
        await submit(tester, 'wear');
        await submit(tester, 'nope'); // Wrong: says so above the field.
        expectNoLayoutErrors(tester);
        await expectAccessible(tester);
        await submit(tester, 'secret');
        expect(find.byType(TextFormField), findsNothing); // Consent.
        expectNoLayoutErrors(tester);
        await expectAccessible(tester);
      }, () => FakeServers().client);
    });

    screen('SSO error', (tester, app) async {
      await http.runWithClient(
        () => startSso(tester, app),
        () => FakeServers(startStatus: 400).client,
      );
      expect(find.textContaining('abswear://oauth'), findsOneWidget);
      expectNoLayoutErrors(tester);
      await expectAccessible(tester);
    });

    screen('logged in, and the logout dialog', (tester, app) async {
      SharedPreferences.setMockInitialValues({
        'serverUrl': 'https://audiobookshelf.example.com',
        'username': 'alice',
        'token': 'tok',
        'defaultLibraryId': 'lib1',
      });
      await tester.pumpWidget(app(const LoginPage()));
      await tester.pumpAndSettle();
      expect(find.byType(ElevatedButton), findsNWidgets(2));
      await expectAccessible(tester);

      await tester.ensureVisible(find.byType(ElevatedButton).last);
      await tester.pumpAndSettle();
      await tester.tap(find.byType(ElevatedButton).last);
      await tester.pumpAndSettle();
      expect(find.byType(AlertDialog), findsOneWidget);
      expectNoLayoutErrors(tester);
      await expectAccessible(tester);
    });
  });

  group('library', () {
    screen('Continue Listening', (tester, app) async {
      routes['GET /api/libraries'] = () => ok({
        'libraries': [
          {'id': 'lib1', 'name': 'Audiobooks', 'mediaType': 'book'},
          {'id': 'lib2', 'name': 'Podcasts', 'mediaType': 'podcast'},
        ],
      });
      routes['GET /api/libraries/lib1/personalized'] = () => ok([
        {
          'id': 'continue-listening',
          'entities': [
            book('li_1', _bookTitle, _author),
            book('li_2', 'Dune', 'Frank Herbert'),
          ],
        },
      ]);
      await http.runWithClient(() async {
        await tester.runAsync(
          () => tester.pumpWidget(
            app(
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
      expect(find.text('Dune'), findsOneWidget);
      await expectAccessible(tester);
    });

    screen('libraries', (tester, app) async {
      await tester.pumpWidget(
        app(
          const LibrariesPage(
            libraries: [
              LibraryInfo(id: 'lib1', name: 'Audiobooks', isPodcast: false),
              LibraryInfo(
                id: 'lib2',
                name: 'Podcasts from all over the world',
                isPodcast: true,
              ),
            ],
            currentId: 'lib1',
          ),
        ),
      );
      await tester.pump();
      await expectAccessible(tester);
    });

    screen('all books', (tester, app) async {
      routes['GET /api/libraries/lib1/items'] = () => ok({
        'total': 100,
        'results': [
          book('li_1', _bookTitle, _author),
          for (var i = 2; i <= 30; i++) book('li_$i', 'Book $i', 'Author $i'),
        ],
      });
      await http.runWithClient(() async {
        await tester.runAsync(
          () => tester.pumpWidget(
            app(
              const BrowsePage(
                serverUrl: _server,
                token: 't',
                libraryId: 'lib1',
                user: 'u',
              ),
            ),
          ),
        );
        await tester.settleRealZone(
          done: () => find.text('Book 2').evaluate().isNotEmpty,
        );
      }, () => client);
      expect(find.text('Book 2'), findsOneWidget);
      await expectAccessible(tester);
    });

    screen('episodes', (tester, app) async {
      final day = DateTime(2026, 11, 8).millisecondsSinceEpoch;
      routes['GET /api/items/pod_1'] = () => ok({
        'id': 'pod_1',
        'media': {
          'episodes': [
            {
              'id': 'ep_1',
              'title': 'An episode with a title long enough to wrap twice',
              'publishedAt': day,
            },
            {'id': 'ep_2', 'title': 'Short', 'publishedAt': day - 86400000},
            {'id': 'ep_3', 'title': 'Done', 'publishedAt': day - 2 * 86400000},
          ],
        },
      });
      routes['GET /api/me'] = () => ok({
        'mediaProgress': [
          {
            'libraryItemId': 'pod_1',
            'episodeId': 'ep_2',
            'progress': 0.3,
            'isFinished': false,
          },
          {
            'libraryItemId': 'pod_1',
            'episodeId': 'ep_3',
            'progress': 1,
            'isFinished': true,
          },
        ],
      });
      await http.runWithClient(() async {
        await tester.runAsync(
          () => tester.pumpWidget(
            app(
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
          done: () => find.text('Short').evaluate().isNotEmpty,
        );
      }, () => client);
      expect(find.text('Short'), findsOneWidget);
      await expectAccessible(tester);
    });

    screen('downloads', (tester, app) async {
      for (final (id, title) in [('li_1', _bookTitle), ('li_2', 'Dune')]) {
        final dir = Directory('${root.path}/docs/$id')..createSync();
        File('${dir.path}/session.json').writeAsStringSync(
          jsonEncode({
            'server': _server,
            'itemId': id,
            'displayTitle': title,
            'displayAuthor': _author,
          }),
        );
      }
      await tester.runAsync(
        () => tester.pumpWidget(
          app(const DownloadsPage(serverUrl: _server, token: 't', user: 'u')),
        ),
      );
      await tester.settleRealZone(
        done: () => find.text('Dune').evaluate().isNotEmpty,
      );
      expect(find.text('Dune'), findsOneWidget);
      await expectAccessible(tester);
    });
  });

  group('player', () {
    AudioPlayerController loaded() => AudioPlayerController()
      ..isLoaded = true
      ..bookTitle = _bookTitle
      ..duration = 36000
      ..chapters = const [
        BookChapter(start: 0, end: 4000, title: 'Chapter 1: A Long-expected'),
      ];

    void expectOnRoundScreen(WidgetTester tester, Finder finder) {
      expect(finder, findsOneWidget);
      expect(
        onRoundScreen(tester, finder),
        isTrue,
        reason:
            '${finder.describeMatch(Plurality.one)} at '
            '${tester.getRect(finder)} is cut off by the round screen',
      );
    }

    screen('now playing', (tester, app) async {
      await tester.pumpWidget(
        app(Scaffold(body: PlayerViewPage(playerController: loaded()))),
      );
      await tester.pump();
      await expectAccessible(tester);
      for (final icon in [
        Icons.skip_previous,
        Icons.play_arrow,
        Icons.skip_next,
        Icons.replay_10_rounded,
        Icons.forward_10_rounded,
      ]) {
        expectOnRoundScreen(tester, find.byIcon(icon));
      }
      expectOnRoundScreen(tester, find.textContaining(':06:40'));
    });

    screen('always-on', (tester, app) async {
      AmbientModeListener.instance.value = true;
      addTearDown(() => AmbientModeListener.instance.value = false);
      await tester.pumpWidget(
        app(
          Theme(
            data: appTheme(ambient: true),
            child: Scaffold(body: PlayerViewPage(playerController: loaded())),
          ),
        ),
      );
      await tester.pump();
      // Dimmed, but still readable.
      await expectAccessible(tester);
      expectOnRoundScreen(tester, find.text('01:06'));
    });

    screen('controls', (tester, app) async {
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            ..setMockStreamHandler(
              const EventChannel(
                'com.kurenai7968.volume_controller.volume_listener_event',
              ),
              MockStreamHandler.inline(
                onListen: (_, sink) => sink.success(0.5),
              ),
            );
      addTearDown(
        () => messenger.setMockStreamHandler(
          const EventChannel(
            'com.kurenai7968.volume_controller.volume_listener_event',
          ),
          null,
        ),
      );
      final controller = loaded();
      await tester.runAsync(
        () => tester.pumpWidget(
          app(ControlViewPage(playerController: controller)),
        ),
      );
      await tester.pump();
      await expectAccessible(tester);
      // The download button, at the bottom, scrolls onto the screen.
      final download = find.byIcon(Icons.download_rounded);
      await tester.runAsync(
        () => Scrollable.ensureVisible(tester.element(download), alignment: .5),
      );
      await tester.pumpAndSettle();
      expectNoLayoutErrors(tester);
      expect(download.hitTestable(), findsOneWidget);
      expectOnRoundScreen(tester, download);
      // Closed while the volume channel is still answered.
      await tester.pumpWidget(const SizedBox());
    });
  });
}
