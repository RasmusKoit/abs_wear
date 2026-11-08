import 'dart:async';

import 'package:abs_wear/l10n/l10n.dart';
import 'package:abs_wear/library/data/json_cache.dart';
import 'package:abs_wear/library/data/library_api.dart';
import 'package:abs_wear/library/view/book_tile.dart';
import 'package:abs_wear/library/view/browse_page.dart';
import 'package:abs_wear/player/player.dart';
import 'package:flutter/material.dart';
import 'package:rotary_scrollbar/rotary_scrollbar.dart';

export 'package:abs_wear/library/data/library_api.dart'
    show LibraryResult, ShelfBook;

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

  /// Continue Listening; null until the cache or the server answered.
  List<ShelfBook>? _books;
  bool _loading = false;
  Object? _error;

  String get _cacheKey =>
      'shelf_${'${widget.serverUrl}|${widget.user}'.hashCode}_'
      '${widget.libraryId}';

  @override
  void initState() {
    super.initState();
    unawaited(_showCachedThenRefresh());
  }

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  /// The saved shelf shows instantly (also offline); the server's answer
  /// replaces it when it arrives.
  Future<void> _showCachedThenRefresh() async {
    final cached = await JsonCache.read(_cacheKey);
    if (!mounted) return;
    if (cached is List && _books == null) {
      setState(() {
        _books = cached
            .cast<Map<String, dynamic>>()
            .map(ShelfBook.fromCache)
            .toList();
      });
    }
    await _refresh();
  }

  /// A refresh asked for while one runs (e.g. after the player closed)
  /// runs again when it finishes.
  bool _refreshAgain = false;

  Future<void> _refresh() async {
    if (_loading) {
      _refreshAgain = true;
      return;
    }
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final books = await _fetchContinueListening();
      if (!mounted) return;
      setState(() => _books = books);
      // Online again: send progress made while offline.
      unawaited(
        AudioPlayerController.pushLocalProgress(
          widget.serverUrl,
          widget.token,
          widget.user,
        ),
      );
      unawaited(
        JsonCache.write(_cacheKey, [for (final b in books) b.toCache()]),
      );
    } on Object catch (e) {
      if (!mounted) return;
      final result = e is ApiException ? e.result : null;
      if (result != null) {
        _close(result);
        return;
      }
      setState(() => _error = e);
    } finally {
      if (mounted) setState(() => _loading = false);
    }
    if (_refreshAgain && mounted) {
      _refreshAgain = false;
      await _refresh();
    }
  }

  Future<List<ShelfBook>> _fetchContinueListening() async {
    final shelves =
        (await getJson(
                  '${widget.serverUrl}/api/libraries/${widget.libraryId}'
                  '/personalized?limit=10',
                  widget.token,
                )
                as List)
            .cast<Map<String, dynamic>>();
    final shelf = shelves.where((s) => s['id'] == 'continue-listening');
    if (shelf.isEmpty) return const [];
    return (shelf.first['entities'] as List)
        .cast<Map<String, dynamic>>()
        .map(ShelfBook.fromJson)
        .toList();
  }

  bool _closing = false;

  void _close(LibraryResult result) {
    // Not while this route is already leaving: pop() would remove the
    // login page underneath.
    final route = mounted ? ModalRoute.of(context) : null;
    if (_closing || route == null || !route.isCurrent) return;
    _closing = true;
    Navigator.of(context).pop(result);
  }

  Future<void> _openBook(ShelfBook book) async {
    await Navigator.push(
      context,
      MaterialPageRoute<void>(
        builder: (context) => PlayerPage(
          token: widget.token,
          serverUrl: widget.serverUrl,
          libraryItemId: book.id,
          user: widget.user,
        ),
      ),
    );
    // Progress changed while listening; reload once the player has sent
    // its final position (it closes after the page transition).
    await Future<void>.delayed(const Duration(milliseconds: 500));
    await AudioPlayerController.lastClose;
    if (mounted) unawaited(_refresh());
  }

  Future<void> _browse() async {
    final result = await Navigator.push(
      context,
      MaterialPageRoute<LibraryResult>(
        builder: (context) => BrowsePage(
          serverUrl: widget.serverUrl,
          token: widget.token,
          libraryId: widget.libraryId,
          user: widget.user,
        ),
      ),
    );
    if (!mounted) return;
    if (result != null) {
      _close(result);
      return;
    }
    // A book opened from the list may still be saving its position.
    await AudioPlayerController.lastClose;
    if (mounted) unawaited(_refresh());
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
              ..._shelf(l10n, theme),
              Card(
                child: ListTile(
                  title: Text(l10n.allBooks, style: theme.textTheme.bodySmall),
                  trailing: const Icon(Icons.library_books_rounded),
                  onTap: () => unawaited(_browse()),
                ),
              ),
              Card(
                child: ListTile(
                  title: Text(l10n.refresh, style: theme.textTheme.bodySmall),
                  trailing: _loading
                      ? const SizedBox.square(
                          dimension: 20,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.refresh),
                  onTap: () => unawaited(_refresh()),
                ),
              ),
              const SizedBox(height: 48),
            ],
          ),
        ),
      ),
    );
  }

  List<Widget> _shelf(AppLocalizations l10n, ThemeData theme) {
    Widget message(String text) => Padding(
      padding: const EdgeInsets.all(8),
      child: Text(
        text,
        textAlign: TextAlign.center,
        style: theme.textTheme.bodySmall,
      ),
    );
    final books = _books;
    if (books == null) {
      return [
        if (_error != null)
          message(errorMessage(l10n, _error))
        else
          const Padding(
            padding: EdgeInsets.all(16),
            child: CircularProgressIndicator(),
          ),
      ];
    }
    return [
      // Showing the saved shelf because the server can't be reached.
      if (_error != null) message(l10n.offlineSavedList),
      if (books.isEmpty) message(l10n.nothingInProgress),
      for (final book in books)
        _BookCard(
          book: book,
          serverUrl: widget.serverUrl,
          token: widget.token,
          onTap: () => unawaited(_openBook(book)),
        ),
    ];
  }
}

class _BookCard extends StatelessWidget {
  const _BookCard({
    required this.book,
    required this.serverUrl,
    required this.token,
    required this.onTap,
  });

  final ShelfBook book;
  final String serverUrl;
  final String token;
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
                  BookCover(
                    serverUrl: serverUrl,
                    token: token,
                    bookId: book.id,
                    size: 50,
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
