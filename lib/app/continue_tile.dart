import 'dart:async';

import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

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

  /// Preference with the signed-in user's shelf key (read by the tile).
  static const shelfPref = 'tileShelf';

  /// Points the tile at the shelf saved under [cacheKey] and redraws it.
  static Future<void> showShelf(String cacheKey) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      if (prefs.getString(shelfPref) != cacheKey) {
        await prefs.setString(shelfPref, cacheKey);
      }
    } on Object {
      // No preferences (tests): the tile keeps showing the app name.
    }
    unawaited(refresh());
  }

  /// Stops the tile showing any shelf (signed out) and redraws it.
  static Future<void> forgetShelf(SharedPreferences prefs) async {
    await prefs.remove(shelfPref);
    unawaited(refresh());
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
