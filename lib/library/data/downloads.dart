import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

/// A book or episode downloaded to the watch.
@immutable
class DownloadedItem {
  const DownloadedItem({
    required this.itemId,
    required this.title,
    required this.author,
    this.episodeId,
    this.coverFile,
  });

  final String itemId;
  final String? episodeId;
  final String title;
  final String author;

  /// Saved cover, if the download has one.
  final File? coverFile;
}

/// Downloads on the watch for [serverUrl], read from the session details
/// saved next to each download (so this works offline). Newest first.
Future<List<DownloadedItem>> listDownloads(String serverUrl) async {
  final docs = await getApplicationDocumentsDirectory();
  final found = <(DownloadedItem, DateTime)>[];
  for (final dir in docs.listSync().whereType<Directory>()) {
    final meta = File('${dir.path}/session.json');
    if (!meta.existsSync()) continue;
    try {
      final json = jsonDecode(meta.readAsStringSync()) as Map<String, dynamic>;
      // Older downloads didn't record their server; show them anyway.
      final server = json['server'] as String?;
      if (server != null && server != serverUrl) continue;
      final metadata = json['mediaMetadata'] as Map<String, dynamic>?;
      final cover = File('${dir.path}/cover.jpg');
      found.add((
        DownloadedItem(
          // Older downloads: the folder is named after the book.
          itemId:
              json['itemId'] as String? ??
              dir.uri.pathSegments.where((s) => s.isNotEmpty).last,
          episodeId: json['episodeId'] as String?,
          title:
              json['displayTitle'] as String? ??
              metadata?['title'] as String? ??
              '',
          author: json['displayAuthor'] as String? ?? '',
          coverFile: cover.existsSync() ? cover : null,
        ),
        meta.lastModifiedSync(),
      ));
    } on Object catch (e) {
      debugPrint('Skipping download ${dir.path}: $e');
    }
  }
  found.sort((a, b) => b.$2.compareTo(a.$2));
  return [for (final (item, _) in found) item];
}
