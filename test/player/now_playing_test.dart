import 'dart:async';

import 'package:abs_wear/library/view/library_page.dart';
import 'package:abs_wear/player/darts/audio_player.dart';
import 'package:abs_wear/player/darts/now_playing.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import '../helpers/helpers.dart';

class _FakeController extends AudioPlayerController {
  _FakeController()
    : super(client: MockClient((_) async => http.Response('', 404)));

  final Completer<bool> setup = Completer<bool>();
  int closes = 0;

  @override
  Future<bool> setupPlayer(
    String libItemId,
    String srvUrl,
    String authToken, {
    String userName = '',
    String? episodeId,
  }) {
    libraryItemId = libItemId;
    serverUrl = srvUrl;
    return setup.future;
  }

  @override
  Future<void> close() {
    closes++;
    return super.close();
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final made = <_FakeController>[];
  final nowPlaying = NowPlaying.instance;

  setUp(() {
    made.clear();
    nowPlaying.create = () {
      final controller = _FakeController();
      made.add(controller);
      return controller;
    };
  });

  tearDown(() async {
    await nowPlaying.stop();
    nowPlaying.create = AudioPlayerController.new;
  });

  ({AudioPlayerController controller, Future<bool> ready, bool created}) open(
    String item,
  ) => nowPlaying.open(
    libraryItemId: item,
    serverUrl: 'http://abs.test',
    token: 't',
    user: 'u',
  );

  test('opening the playing book again attaches to it', () async {
    final first = open('li_1');
    made.single.setup.complete(true);
    expect(await first.ready, isTrue);

    final again = open('li_1');
    expect(again.created, isFalse);
    expect(again.controller, same(first.controller));
    expect(await again.ready, isTrue);
    expect(made, hasLength(1));
    expect(made.single.closes, 0);
    expect(nowPlaying.controller, same(first.controller));
  });

  test('another book replaces the playing one, closing it', () async {
    final first = open('li_1');
    made.first.setup.complete(true);
    await first.ready;

    final second = open('li_2');
    expect(second.created, isTrue);
    expect(made.first.closes, 1);
    expect(made.first.isOpen, isFalse);
    expect(nowPlaying.controller, same(second.controller));
    made.last.setup.complete(true);
    expect(await second.ready, isTrue);
  });

  test('a book replaced while starting reports not ready', () async {
    final first = open('li_1');
    open('li_2');
    made.first.setup.complete(false);
    expect(await first.ready, isFalse);
    expect(nowPlaying.controller, same(made.last));
  });

  test('a book that fails to start is let go', () async {
    var changes = 0;
    void listener() => changes++;
    nowPlaying.addListener(listener);
    addTearDown(() => nowPlaying.removeListener(listener));

    final opened = open('li_1');
    made.single.setup.complete(false);
    expect(await opened.ready, isFalse);
    expect(nowPlaying.controller, isNull);
    expect(made.single.closes, 1);
    expect(changes, 2);
  });

  test('stop closes the playing book', () async {
    final opened = open('li_1');
    made.single.setup.complete(true);
    await opened.ready;

    await nowPlaying.stop();
    expect(nowPlaying.controller, isNull);
    expect(made.single.closes, 1);
  });

  testWidgets('the now playing card names the book and opens it', (
    tester,
  ) async {
    final controller = _FakeController()
      ..bookTitle = 'Dune'
      ..isLoaded = true;
    var opened = 0;
    await tester.pumpApp(
      Scaffold(
        body: NowPlayingCard(controller: controller, onTap: () => opened++),
      ),
    );
    await tester.pump();

    expect(find.text('Dune'), findsOneWidget);
    expect(find.byTooltip('Play'), findsOneWidget);
    await tester.tap(find.text('Dune'));
    expect(opened, 1);
  });
}
