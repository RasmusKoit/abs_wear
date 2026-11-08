import 'dart:async';
import 'dart:convert';

import 'package:abs_wear/l10n/l10n.dart';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

/// A book, podcast or podcast episode as shown in lists (shelves, library
/// browser).
@immutable
class ShelfBook {
  const ShelfBook({
    required this.id,
    required this.title,
    required this.author,
    this.isPodcast = false,
    this.episodeId,
  });

  /// From a library item as the server returns it. A shelf entry with a
  /// `recentEpisode` (Continue Listening in a podcast library) is that
  /// episode.
  factory ShelfBook.fromJson(Map<String, dynamic> json) {
    final media = json['media'] as Map<String, dynamic>? ?? const {};
    final metadata = media['metadata'] as Map<String, dynamic>? ?? const {};
    final isPodcast = json['mediaType'] == 'podcast';
    final title = metadata['title'] as String? ?? '';
    final episode = json['recentEpisode'];
    if (episode is Map<String, dynamic> && episode['id'] is String) {
      return ShelfBook(
        id: json['id'] as String,
        title: episode['title'] as String? ?? '',
        author: title,
        isPodcast: true,
        episodeId: episode['id'] as String,
      );
    }
    return ShelfBook(
      id: json['id'] as String,
      title: title,
      author:
          (isPodcast ? metadata['author'] : metadata['authorName'])
              as String? ??
          '',
      isPodcast: isPodcast,
    );
  }

  /// From the compact form written by [toCache].
  factory ShelfBook.fromCache(Map<String, dynamic> json) => ShelfBook(
    id: json['i'] as String,
    title: json['t'] as String? ?? '',
    author: json['a'] as String? ?? '',
    isPodcast: json['p'] == true,
    episodeId: json['e'] as String?,
  );

  final String id;
  final String title;
  final String author;
  final bool isPodcast;

  /// Set for a podcast episode; [id] is then its podcast.
  final String? episodeId;

  Map<String, Object> toCache() => {
    'i': id,
    't': title,
    'a': author,
    if (isPodcast) 'p': true,
    'e': ?episodeId,
  };
}

/// A library on the server.
@immutable
class LibraryInfo {
  const LibraryInfo({
    required this.id,
    required this.name,
    required this.isPodcast,
  });

  factory LibraryInfo.fromJson(Map<String, dynamic> json) => LibraryInfo(
    id: json['id'] as String,
    name: json['name'] as String? ?? '',
    isPodcast: json['mediaType'] == 'podcast',
  );

  final String id;
  final String name;
  final bool isPodcast;

  Map<String, Object> toJson() => {
    'id': id,
    'name': name,
    'mediaType': isPodcast ? 'podcast' : 'book',
  };
}

/// Book and podcast libraries the user can open (other kinds are skipped).
Future<List<LibraryInfo>> fetchLibraries(String serverUrl, String token) async {
  final json =
      await getJson('$serverUrl/api/libraries', token) as Map<String, dynamic>;
  return (json['libraries'] as List)
      .cast<Map<String, dynamic>>()
      .where((l) => l['mediaType'] == 'book' || l['mediaType'] == 'podcast')
      .map(LibraryInfo.fromJson)
      .toList();
}

/// Why a library page closed itself, for the login page to act on.
enum LibraryResult {
  /// The server rejected the token (401): log in again.
  sessionExpired,

  /// The saved library no longer exists (404): pick another one.
  libraryMissing,

  /// The user picked another library (saved as the default): open it.
  switchLibrary,
}

/// A non-200 reply from the server.
class ApiException implements Exception {
  const ApiException(this.statusCode);
  final int statusCode;

  LibraryResult? get result => switch (statusCode) {
    401 => LibraryResult.sessionExpired,
    404 => LibraryResult.libraryMissing,
    _ => null,
  };

  @override
  String toString() => 'HTTP $statusCode';
}

/// GETs [url] and decodes the JSON body; throws [ApiException] on non-200.
Future<Object> getJson(String url, String token) async {
  final response = await http
      .get(Uri.parse(url), headers: {'Authorization': 'Bearer $token'})
      .timeout(const Duration(seconds: 20));
  if (response.statusCode != 200) throw ApiException(response.statusCode);
  return jsonDecode(response.body) as Object;
}

/// A short, user-facing message for a failed request.
String errorMessage(AppLocalizations l10n, Object? error) {
  if (error is TimeoutException) return l10n.serverTimeout;
  if (error is ApiException) return l10n.errorLoadingData;
  // IOClient wraps socket/DNS failures in ClientException.
  if (error is http.ClientException) return l10n.cannotReachServer;
  return l10n.errorLoadingData; // Unexpected response shape.
}
