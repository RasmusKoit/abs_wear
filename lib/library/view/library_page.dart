import 'dart:async';
import 'dart:convert';

import 'package:abs_wear/l10n/l10n.dart';
import 'package:abs_wear/player/player.dart';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:rotary_scrollbar/rotary_scrollbar.dart';

/// Why the library page closed itself, for the login page to act on.
enum LibraryResult {
  /// The server rejected the token (401): log in again.
  sessionExpired,

  /// The saved library no longer exists (404): pick another one.
  libraryMissing,
}

/// A book on the "Continue Listening" shelf.
@immutable
class ShelfBook {
  const ShelfBook({
    required this.id,
    required this.title,
    required this.author,
  });

  factory ShelfBook.fromJson(Map<String, dynamic> json) {
    final media = json['media'] as Map<String, dynamic>? ?? const {};
    final metadata = media['metadata'] as Map<String, dynamic>? ?? const {};
    return ShelfBook(
      id: json['id'] as String,
      title: metadata['title'] as String? ?? '',
      author: metadata['authorName'] as String? ?? '',
    );
  }

  final String id;
  final String title;
  final String author;
}

class LibraryPage extends StatefulWidget {
  const LibraryPage({
    required this.token,
    required this.serverUrl,
    required this.libraryId,
    required this.user,
    super.key,
  });
  final String token;
  final String serverUrl;
  final String libraryId;
  final String user;

  @override
  State<LibraryPage> createState() => _LibraryPageState();
}

class _LibraryPageState extends State<LibraryPage> {
  final _scrollController = ScrollController();
  late Future<List<ShelfBook>> _books;

  Map<String, String> get _authHeaders => {
    'Authorization': 'Bearer ${widget.token}',
  };

  @override
  void initState() {
    super.initState();
    // Fetch once here; fetching inside build() refetched on every rebuild.
    _books = _fetchContinueListening();
  }

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  Future<List<ShelfBook>> _fetchContinueListening() async {
    final response = await http
        .get(
          Uri.parse(
            '${widget.serverUrl}/api/libraries/${widget.libraryId}'
            '/personalized?limit=10',
          ),
          headers: _authHeaders,
        )
        .timeout(const Duration(seconds: 20));
    if (response.statusCode == 401 || response.statusCode == 404) {
      _close(
        response.statusCode == 401
            ? LibraryResult.sessionExpired
            : LibraryResult.libraryMissing,
      );
    }
    if (response.statusCode != 200) {
      throw _ShelfLoadException(response.statusCode);
    }
    final shelves = (jsonDecode(response.body) as List)
        .cast<Map<String, dynamic>>();
    final shelf = shelves.where((s) => s['id'] == 'continue-listening');
    if (shelf.isEmpty) return const [];
    return (shelf.first['entities'] as List)
        .cast<Map<String, dynamic>>()
        .map(ShelfBook.fromJson)
        .toList();
  }

  bool _closing = false;

  String _errorMessage(AppLocalizations l10n, Object? error) {
    if (error is TimeoutException) return l10n.serverTimeout;
    if (error is _ShelfLoadException) return l10n.errorLoadingData;
    // IOClient wraps socket/DNS failures in ClientException.
    if (error is http.ClientException) return l10n.cannotReachServer;
    return l10n.errorLoadingData; // Unexpected response shape.
  }

  void _close(LibraryResult result) {
    // Not while this route is already leaving: pop() would remove the
    // login page underneath.
    final route = mounted ? ModalRoute.of(context) : null;
    if (_closing || route == null || !route.isCurrent) return;
    _closing = true;
    Navigator.of(context).pop(result);
  }

  void _refresh() {
    final books = _fetchContinueListening();
    setState(() {
      _books = books;
    });
  }

  Future<void> _openBook(ShelfBook book) async {
    await Navigator.push(
      context,
      MaterialPageRoute<void>(
        builder: (context) => PlayerPage(
          token: widget.token,
          serverUrl: widget.serverUrl,
          libraryItemId: book.id,
        ),
      ),
    );
    // Progress changed while listening; reload so ordering is current.
    if (mounted) _refresh();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    return RotaryScrollbar(
      width: 2,
      padding: 1,
      hasHapticFeedback: false,
      autoHide: false,
      controller: _scrollController,
      child: Scaffold(
        appBar: PreferredSize(
          preferredSize: const Size.fromHeight(40),
          child: AppBar(
            centerTitle: true,
            title: Text(l10n.library, style: theme.textTheme.bodyLarge),
            automaticallyImplyLeading: false,
          ),
        ),
        body: SingleChildScrollView(
          controller: _scrollController,
          padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 8),
          child: Column(
            children: [
              Text(l10n.continueListening),
              FutureBuilder<List<ShelfBook>>(
                future: _books,
                builder: (context, snapshot) {
                  if (snapshot.connectionState != ConnectionState.done) {
                    return const Padding(
                      padding: EdgeInsets.all(16),
                      child: CircularProgressIndicator(),
                    );
                  }
                  if (snapshot.hasError) {
                    return Padding(
                      padding: const EdgeInsets.all(8),
                      child: Text(
                        _errorMessage(l10n, snapshot.error),
                        textAlign: TextAlign.center,
                        style: theme.textTheme.bodySmall,
                      ),
                    );
                  }
                  if (snapshot.data!.isEmpty) {
                    return Padding(
                      padding: const EdgeInsets.all(8),
                      child: Text(
                        l10n.nothingInProgress,
                        textAlign: TextAlign.center,
                        style: theme.textTheme.bodySmall,
                      ),
                    );
                  }
                  return Column(
                    children: [
                      for (final book in snapshot.data!)
                        _BookCard(
                          book: book,
                          coverUrl:
                              '${widget.serverUrl}/api/items/'
                              '${book.id}/cover?width=100',
                          headers: _authHeaders,
                          onTap: () => unawaited(_openBook(book)),
                        ),
                    ],
                  );
                },
              ),
              Card(
                child: ListTile(
                  title: Text(l10n.refresh, style: theme.textTheme.bodySmall),
                  trailing: const Icon(Icons.refresh),
                  onTap: _refresh,
                ),
              ),
              const SizedBox(height: 48),
            ],
          ),
        ),
      ),
    );
  }
}

class _ShelfLoadException implements Exception {
  const _ShelfLoadException(this.statusCode);
  final int statusCode;

  @override
  String toString() => 'Failed to load shelves (HTTP $statusCode)';
}

class _BookCard extends StatelessWidget {
  const _BookCard({
    required this.book,
    required this.coverUrl,
    required this.headers,
    required this.onTap,
  });

  final ShelfBook book;
  final String coverUrl;
  final Map<String, String> headers;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return InkWell(
      onTap: onTap,
      child: Card(
        child: Padding(
          padding: const EdgeInsets.all(8),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(book.title, style: theme.textTheme.bodySmall),
              const Divider(),
              Row(
                children: [
                  Expanded(
                    child: Text(book.author, style: theme.textTheme.labelSmall),
                  ),
                  Image.network(
                    coverUrl,
                    // Token in a header, not the URL (URLs end up in logs).
                    headers: headers,
                    width: 50,
                    height: 50,
                    cacheWidth: 100,
                    // Books without cover art return 404; show a placeholder
                    // instead of Flutter's oversized error widget.
                    errorBuilder: (_, _, _) => const SizedBox.square(
                      dimension: 50,
                      child: Icon(Icons.book_rounded),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}
