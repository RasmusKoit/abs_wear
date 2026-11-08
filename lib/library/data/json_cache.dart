import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

/// Small on-disk cache for server lists (shelves, library pages), so the
/// app shows something instantly and keeps working offline.
///
/// Lives in the app support directory, apart from downloaded books.
class JsonCache {
  const JsonCache._();

  static Future<Directory> _dir() async {
    final support = await getApplicationSupportDirectory();
    return Directory('${support.path}/json_cache');
  }

  static String _fileName(String key) =>
      '${key.replaceAll(RegExp('[^A-Za-z0-9_-]'), '_')}.json';

  /// The cached value for [key], or null when missing or unreadable.
  static Future<Object?> read(String key) async {
    try {
      final file = File('${(await _dir()).path}/${_fileName(key)}');
      if (!file.existsSync()) return null;
      return jsonDecode(await file.readAsString());
    } on Object catch (e) {
      debugPrint('Cache read failed for $key: $e');
      return null;
    }
  }

  /// Writes to the same key run one after another.
  static final Map<String, Future<void>> _writes = {};

  static Future<void> write(String key, Object? value) async {
    final previous = _writes[key] ?? Future<void>.value();
    final done = Completer<void>();
    _writes[key] = done.future;
    try {
      await previous;
      await _write(key, value);
    } finally {
      done.complete();
      if (identical(_writes[key], done.future)) unawaited(_writes.remove(key));
    }
  }

  static Future<void> _write(String key, Object? value) async {
    try {
      final dir = await _dir();
      dir.createSync(recursive: true);
      final file = File('${dir.path}/${_fileName(key)}');
      // Write then rename, so a crash never leaves half a file.
      final tmp = File('${file.path}.tmp');
      await tmp.writeAsString(jsonEncode(value), flush: true);
      tmp.renameSync(file.path);
    } on Object catch (e) {
      debugPrint('Cache write failed for $key: $e');
    }
  }

  /// Removes everything (e.g. on logout).
  static Future<void> clear() async {
    try {
      final dir = await _dir();
      if (dir.existsSync()) dir.deleteSync(recursive: true);
    } on Object catch (e) {
      debugPrint('Cache clear failed: $e');
    }
  }
}
