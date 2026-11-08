import 'dart:async';

import 'package:abs_wear/app/view/crown_scrollbar.dart';
import 'package:abs_wear/l10n/l10n.dart';
import 'package:abs_wear/library/data/json_cache.dart';
import 'package:abs_wear/library/data/library_api.dart';
import 'package:abs_wear/library/view/book_tile.dart';
import 'package:abs_wear/player/player.dart';
import 'package:flutter/material.dart';

/// Every book in the library, A to Z, loaded a page at a time as the user
/// scrolls, so libraries with thousands of books stay fast and light.
class BrowsePage extends StatefulWidget {
  const BrowsePage({
    required this.serverUrl,
    required this.token,
    required this.libraryId,
    required this.user,
    super.key,
  });

  final String serverUrl;
  final String token;
  final String libraryId;

  /// Part of the cache key, so another account never sees this list.
  final String user;

  @override
  State<BrowsePage> createState() => _BrowsePageState();
}

class _BrowsePageState extends State<BrowsePage> {
  static const _pageSize = 30;

  /// Start loading the next page this many rows before the end.
  static const _prefetchRows = 8;

  final _scrollController = ScrollController();
  final List<ShelfBook> _books = [];

  /// Total on the server; null until known (from the cache or server).
  int? _total;

  /// The server returned a short page: nothing more to load.
  bool _reachedEnd = false;

  /// Page 0 was checked against the server this visit. Until then paging
  /// waits, so it can't mix with a list that is about to be replaced.
  bool _validated = false;
  int _nextPage = 0;
  bool _loading = false;
  Object? _error;

  /// Bumped when the list restarts; replies for older lists are dropped.
  int _generation = 0;

  /// True while showing the saved list because the server is unreachable.
  bool get _offline => _error != null && !_validated && _books.isNotEmpty;

  String get _cacheKey =>
      'browse_${'${widget.serverUrl}|${widget.user}'.hashCode}_'
      '${widget.libraryId}';

  bool get _hasMore =>
      !_reachedEnd && (_total == null || _books.length < _total!);

  @override
  void initState() {
    super.initState();
    unawaited(_showCached().then((_) => _checkFirstPage()));
  }

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  Future<void> _showCached() async {
    final cached = await JsonCache.read(_cacheKey);
    if (!mounted || cached is! Map<String, dynamic>) return;
    final books = cached['books'];
    if (books is! List) return;
    setState(() {
      _books.addAll(
        books.cast<Map<String, dynamic>>().map(ShelfBook.fromCache),
      );
      _total = cached['total'] as int?;
    });
  }

  /// Compares the server's first page with what is shown: if it still
  /// matches, paging continues after the saved books; if the library
  /// changed, the list starts over from the server.
  Future<void> _checkFirstPage() async {
    final generation = ++_generation;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final (page, total) = await _fetchPage(0);
      if (!mounted || generation != _generation) return;
      final unchanged =
          _books.length >= page.length &&
          total == _total &&
          [
            for (var i = 0; i < page.length; i++) page[i].id == _books[i].id,
          ].every((same) => same);
      setState(() {
        if (!unchanged) {
          _books
            ..clear()
            ..addAll(page);
        }
        _total = total;
        _reachedEnd = page.length < _pageSize || _books.length >= total;
        _nextPage = (_books.length / _pageSize).ceil();
        _validated = true;
      });
      unawaited(_save());
    } on Object catch (e) {
      if (!mounted || generation != _generation || _handleAuthError(e)) {
        return;
      }
      setState(() => _error = e);
    } finally {
      if (mounted && generation == _generation) {
        setState(() => _loading = false);
      }
    }
  }

  Future<(List<ShelfBook>, int)> _fetchPage(int page) async {
    final json =
        await getJson(
              '${widget.serverUrl}/api/libraries/${widget.libraryId}/items'
              '?limit=$_pageSize&page=$page'
              '&sort=media.metadata.title&minified=1',
              widget.token,
            )
            as Map<String, dynamic>;
    final books = (json['results'] as List)
        .cast<Map<String, dynamic>>()
        .map(ShelfBook.fromJson)
        .toList();
    return (books, (json['total'] as num).toInt());
  }

  Future<void> _loadMore() async {
    // A failed load waits for the user's retry instead of looping.
    if (_loading || !_validated || !_hasMore || _error != null) return;
    final generation = _generation;
    final pageNumber = _nextPage;
    setState(() => _loading = true);
    try {
      final (page, total) = await _fetchPage(pageNumber);
      if (!mounted || generation != _generation) return;
      setState(() {
        // Skip duplicates in case the library changed while paging.
        final known = {for (final b in _books) b.id};
        _books.addAll(page.where((b) => !known.contains(b.id)));
        _total = total;
        _nextPage = pageNumber + 1;
        _reachedEnd = page.length < _pageSize;
      });
      unawaited(_save());
    } on Object catch (e) {
      if (!mounted || generation != _generation || _handleAuthError(e)) {
        return;
      }
      setState(() => _error = e);
    } finally {
      if (mounted && generation == _generation) {
        setState(() => _loading = false);
      }
    }
  }

  Future<void> _save() => JsonCache.write(_cacheKey, {
    'total': _total,
    'books': [for (final b in _books) b.toCache()],
  });

  /// 401/404: leave, and let the library and login pages handle it.
  /// Returns true when handled (also while another page is on top, so
  /// the error isn't retried in a loop).
  bool _handleAuthError(Object e) {
    final result = e is ApiException ? e.result : null;
    if (result == null) return false;
    _error = e;
    final route = ModalRoute.of(context);
    if (route != null && route.isCurrent) Navigator.of(context).pop(result);
    return true;
  }

  void _retry() {
    if (_loading) return;
    if (!_validated) {
      unawaited(_checkFirstPage());
    } else {
      setState(() => _error = null);
      unawaited(_loadMore());
    }
  }

  Future<void> _open(ShelfBook book) => Navigator.push(
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

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    final showFooter = _hasMore || _error != null || _loading;
    return CrownScrollbar(
      controller: _scrollController,
      child: Scaffold(
        appBar: PreferredSize(
          preferredSize: const Size.fromHeight(40),
          child: AppBar(
            centerTitle: true,
            automaticallyImplyLeading: false,
            title: Text(
              _total == null ? l10n.allBooks : l10n.bookCount(_total!),
              style: theme.textTheme.bodyLarge,
            ),
          ),
        ),
        body: ListView.builder(
          controller: _scrollController,
          // Round screen: keep rows away from the clipped corners.
          padding: const EdgeInsets.fromLTRB(28, 4, 24, 48),
          itemExtent: BookTile.height,
          itemCount: _books.length + (showFooter ? 1 : 0),
          itemBuilder: (context, index) {
            if (index >= _books.length) return _footer(l10n, theme);
            if (index >= _books.length - _prefetchRows) {
              // Near the end: fetch the next page after this frame.
              WidgetsBinding.instance.addPostFrameCallback((_) {
                if (mounted) unawaited(_loadMore());
              });
            }
            final book = _books[index];
            return BookTile(
              key: ValueKey(book.id),
              book: book,
              serverUrl: widget.serverUrl,
              token: widget.token,
              onTap: () => unawaited(_open(book)),
            );
          },
        ),
      ),
    );
  }

  Widget _footer(AppLocalizations l10n, ThemeData theme) {
    if (_error != null || _offline) {
      return InkWell(
        onTap: _retry,
        child: Center(
          child: Text(
            _offline ? l10n.offlineSavedList : errorMessage(l10n, _error),
            textAlign: TextAlign.center,
            maxLines: 2,
            style: theme.textTheme.labelSmall,
          ),
        ),
      );
    }
    return const Center(
      child: SizedBox.square(
        dimension: 24,
        child: CircularProgressIndicator(strokeWidth: 2),
      ),
    );
  }
}
