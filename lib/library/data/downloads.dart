import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

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
/// The files are scanned off the UI isolate.
Future<List<DownloadedItem>> listDownloads(String serverUrl) async {
  final docs = (await getApplicationDocumentsDirectory()).path;
  return await Isolate.run(() => _scan(docs, serverUrl));
}

List<DownloadedItem> _scan(String docsPath, String serverUrl) {
  final found = <(DownloadedItem, DateTime)>[];
  final docs = Directory(docsPath);
  if (!docs.existsSync()) return const [];
  for (final dir in docs.listSync().whereType<Directory>()) {
    try {
      final meta = File('${dir.path}/session.json');
      if (!meta.existsSync()) continue;
      final json = jsonDecode(meta.readAsStringSync()) as Map<String, dynamic>;
      // Downloads from before the server and ids were recorded are left
      // out (they can't be matched to this server); playing them online
      // once records them.
      final itemId = json['itemId'] as String?;
      if (json['server'] != serverUrl || itemId == null) continue;
      final metadata = json['mediaMetadata'] as Map<String, dynamic>?;
      final cover = File('${dir.path}/cover.jpg');
      found.add((
        DownloadedItem(
          itemId: itemId,
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
