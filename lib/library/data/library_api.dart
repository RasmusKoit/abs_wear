import 'dart:async';
import 'dart:convert';

import 'package:abs_wear/l10n/l10n.dart';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

/// A book as shown in lists (shelves, library browser).
@immutable
class ShelfBook {
  const ShelfBook({
    required this.id,
    required this.title,
    required this.author,
  });

  /// From a library item as the server returns it.
  factory ShelfBook.fromJson(Map<String, dynamic> json) {
    final media = json['media'] as Map<String, dynamic>? ?? const {};
    final metadata = media['metadata'] as Map<String, dynamic>? ?? const {};
    return ShelfBook(
      id: json['id'] as String,
      title: metadata['title'] as String? ?? '',
      author: metadata['authorName'] as String? ?? '',
    );
  }

  /// From the compact form written by [toCache].
  factory ShelfBook.fromCache(Map<String, dynamic> json) => ShelfBook(
    id: json['i'] as String,
    title: json['t'] as String? ?? '',
    author: json['a'] as String? ?? '',
  );

  final String id;
  final String title;
  final String author;

  Map<String, String> toCache() => {'i': id, 't': title, 'a': author};
}

/// Why a library page closed itself, for the login page to act on.
enum LibraryResult {
  /// The server rejected the token (401): log in again.
  sessionExpired,

  /// The saved library no longer exists (404): pick another one.
  libraryMissing,
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
