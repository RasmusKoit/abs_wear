import 'dart:async';

import 'package:flutter/services.dart';

/// A book the "Continue listening" tile asked to open.
class TileOpen {
  const TileOpen({required this.id, this.episodeId});

  final String id;
  final String? episodeId;
}

/// The watch tile (ContinueTileService), through MainActivity.
class ContinueTile {
  const ContinueTile._();

  static const channel = MethodChannel('continue_tile');

  static final _opens = StreamController<void>.broadcast();
  static bool _handling = false;

  /// Fires when a tile tap reaches the running app; [take] returns the book.
  static Stream<void> get opens {
    if (!_handling) {
      _handling = true;
      channel.setMethodCallHandler((call) async {
        if (call.method == 'open') _opens.add(null);
      });
    }
    return _opens.stream;
  }

  /// The book a tile tap asked for, once; null when there is none.
  static Future<TileOpen?> take() async {
    try {
      final open = await channel.invokeMapMethod<String, Object?>('take');
      final id = open?['id'];
      if (id is! String || id.isEmpty) return null;
      final episode = open?['episodeId'];
      return TileOpen(id: id, episodeId: episode is String ? episode : null);
    } on Exception {
      return null;
    }
  }

  /// Asks the system to redraw the tile; fails silently (e.g. in tests).
  static Future<void> refresh() async {
    try {
      await channel.invokeMethod<void>('refresh');
    } on Exception {
      // No platform side (tests).
    }
  }
}
