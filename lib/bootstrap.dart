import 'dart:async';
import 'dart:developer';
import 'dart:ui';

import 'package:audio_session/audio_session.dart';
import 'package:flutter/widgets.dart';

Future<void> bootstrap(FutureOr<Widget> Function() builder) async {
  FlutterError.onError = (details) {
    log(details.exceptionAsString(), stackTrace: details.stack);
  };
  // Errors from un-awaited futures (syncs, closes) would otherwise be lost.
  PlatformDispatcher.instance.onError = (error, stack) {
    log('$error', stackTrace: stack);
    return true;
  };

  // Watches have little memory: bound the decoded-image cache (book
  // covers) well below Flutter's phone-sized default (1000 images/100 MB).
  PaintingBinding.instance.imageCache
    ..maximumSize = 150
    ..maximumSizeBytes = 24 << 20;

  // Spoken audio: pause (rather than duck under) notifications and prompts.
  final session = await AudioSession.instance;
  await session.configure(const AudioSessionConfiguration.speech());

  runApp(await builder());
}
