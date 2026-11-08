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

  // Spoken audio: pause (rather than duck under) notifications and prompts.
  final session = await AudioSession.instance;
  await session.configure(const AudioSessionConfiguration.speech());

  runApp(await builder());
}
