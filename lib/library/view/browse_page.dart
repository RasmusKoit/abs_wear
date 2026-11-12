import 'dart:async';

import 'package:abs_wear/app/view/crown_scrollbar.dart';
import 'package:abs_wear/l10n/l10n.dart';
import 'package:abs_wear/library/data/json_cache.dart';
import 'package:abs_wear/library/data/library_api.dart';
import 'package:abs_wear/library/view/book_tile.dart';
import 'package:abs_wear/library/view/search_page.dart';
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// How the library browser orders the list.
enum BrowseSort {
  title('sort=media.metadata.title'),
  added('sort=addedAt&desc=1');

  const BrowseSort(this.query);

  /// The items request's sort parameters.
  final String query;
}

/// Every book (or podcast) in the library, A to Z or newest first, loaded a
/// page at a time as the user scrolls, so libraries with thousands of books
/// stay fast and light.
class BrowsePage extends StatefulWidget {
  const BrowsePage({
    required this.serverUrl,
    required this.token,
    required this.libraryId,
    required this.user,
    this.isPodcast = false,
    super.key,
  });

  /// A podcast library: items open their episode list.
  final bool isPodcast;

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

  /// Remembers the chosen sort across visits.
  static const _sortKey = 'browseSort';

  /// The list is saved this long after it last grew, and when leaving.
  static const _saveDelay = Duration(seconds: 5);

  final _scrollController = ScrollController();
  final List<ShelfBook> _books = [];

  /// Ids in [_books], to skip duplicates while paging.
  final Set<String> _ids = {};

  BrowseSort _sort = BrowseSort.title;

  /// The list changed since it was last saved.
  bool _dirty = false;
  Timer? _saveTimer;

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

  /// One saved list per sort; title keeps the key from before sorting.
  String get _cacheKey =>
      'browse_${'${widget.serverUrl}|${widget.user}'.hashCode}_'
      '${widget.libraryId}${_sort == BrowseSort.title ? '' : '_${_sort.name}'}';

  bool get _hasMore =>
      !_reachedEnd && (_total == null || _books.length < _total!);

  @override
  void initState() {
    super.initState();
    unawaited(_start());
  }

  @override
  void dispose() {
    _flush();
    _scrollController.dispose();
    super.dispose();
  }

  Future<void> _start() async {
    final generation = _generation;
    final saved = await _savedSort();
    if (!mounted || generation != _generation) return;
    setState(() => _sort = saved);
    await _showCached(generation);
    if (generation == _generation) await _checkFirstPage();
  }

  static Future<BrowseSort> _savedSort() async {
    try {
      final name = (await SharedPreferences.getInstance()).getString(_sortKey);
      return BrowseSort.values.asNameMap()[name] ?? BrowseSort.title;
    } on Object catch (e) {
      debugPrint('Reading the browse sort failed: $e');
      return BrowseSort.title;
    }
  }

  Future<void> _toggleSort() async {
    _flush();
    final next = _sort == BrowseSort.title
        ? BrowseSort.added
        : BrowseSort.title;
    final generation = ++_generation;
    setState(() {
      _sort = next;
      _books.clear();
      _ids.clear();
      _total = null;
      _reachedEnd = false;
      _validated = false;
      _nextPage = 0;
      _loading = false;
      _error = null;
    });
    if (_scrollController.hasClients) _scrollController.jumpTo(0);
    unawaited(_saveSort(next));
    await _showCached(generation);
    if (generation == _generation) await _checkFirstPage();
  }

  static Future<void> _saveSort(BrowseSort sort) async {
    try {
      await (await SharedPreferences.getInstance()).setString(
        _sortKey,
        sort.name,
      );
    } on Object catch (e) {
      debugPrint('Saving the browse sort failed: $e');
    }
  }

  Future<void> _showCached(int generation) async {
    final cached = await JsonCache.read(_cacheKey);
    if (!mounted || generation != _generation) return;
    if (cached is! Map<String, dynamic>) return;
    final books = cached['books'];
    if (books is! List) return;
    setState(() {
      _add(books.cast<Map<String, dynamic>>().map(ShelfBook.fromCache));
      _total = cached['total'] as int?;
    });
  }

  /// Appends the [books] that aren't listed yet.
  void _add(Iterable<ShelfBook> books) =>
      _books.addAll(books.where((b) => _ids.add(b.id)));

  /// Compares the server's first page with what is shown: if it still
  /// matches, paging continues after the saved books; if the library
  /// changed, the list starts over from the server.
  Future<void> _checkFirstPage() async {
    // Runs after the cache read, which may finish after the user left.
    if (!mounted) return;
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
          _books.clear();
          _ids.clear();
          _add(page);
          _markDirty();
        }
        _total = total;
        _reachedEnd = page.length < _pageSize || _books.length >= total;
        _nextPage = (_books.length / _pageSize).ceil();
        _validated = true;
      });
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
              '&${_sort.query}&minified=1',
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
        // Skips duplicates in case the library changed while paging.
        _add(page);
        _total = total;
        _nextPage = pageNumber + 1;
        _reachedEnd = page.length < _pageSize;
      });
      _markDirty();
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

  void _markDirty() {
    _dirty = true;
    _saveTimer?.cancel();
    _saveTimer = Timer(_saveDelay, _flush);
  }

  /// Writes the list if it changed since the last write.
  void _flush() {
    _saveTimer?.cancel();
    _saveTimer = null;
    if (!_dirty) return;
    _dirty = false;
    unawaited(
      JsonCache.write(_cacheKey, {
        'total': _total,
        'books': [for (final b in _books) b.toCache()],
      }),
    );
  }

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

  Future<void> _open(ShelfBook book) => _closeWith(
    openShelfBook(
      context,
      book,
      serverUrl: widget.serverUrl,
      token: widget.token,
      user: widget.user,
    ),
  );

  Future<void> _openSearch() => _closeWith(
    Navigator.push(
      context,
      MaterialPageRoute<LibraryResult>(
        builder: (context) => SearchPage(
          serverUrl: widget.serverUrl,
          token: widget.token,
          libraryId: widget.libraryId,
          user: widget.user,
        ),
      ),
    ),
  );

  /// Passes on why a page on top closed the library, if it did.
  Future<void> _closeWith(Future<LibraryResult?> page) async {
    final result = await page;
    if (result == null || !mounted) return;
    final route = ModalRoute.of(context);
    if (route != null && route.isCurrent) Navigator.of(context).pop(result);
  }

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
            // Inset so the ellipsis stays inside the round screen.
            title: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 40),
              child: Text(
                switch ((widget.isPodcast, _total)) {
                  (false, null) => l10n.allBooks,
                  (true, null) => l10n.allPodcasts,
                  (false, final total?) => l10n.bookCount(total),
                  (true, final total?) => l10n.podcastCount(total),
                },
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.bodyLarge,
              ),
            ),
          ),
        ),
        body: ListView.builder(
          controller: _scrollController,
          // Round screen: keep rows away from the clipped corners.
          padding: const EdgeInsets.fromLTRB(28, 4, 24, 48),
          itemExtent: BookTile.height,
          itemCount: 1 + _books.length + (showFooter ? 1 : 0),
          itemBuilder: (context, row) {
            if (row == 0) return _header(l10n, theme);
            final index = row - 1;
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

  /// Search and the sort toggle, above the list.
  Widget _header(AppLocalizations l10n, ThemeData theme) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        IconButton(
          icon: const Icon(Icons.search_rounded),
          tooltip: l10n.search,
          onPressed: () => unawaited(_openSearch()),
        ),
        Flexible(
          child: TextButton.icon(
            icon: const Icon(Icons.sort_rounded, size: 20),
            label: Text(
              switch (_sort) {
                BrowseSort.title => l10n.sortByTitle,
                BrowseSort.added => l10n.sortByAdded,
              },
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.labelSmall,
            ),
            onPressed: () => unawaited(_toggleSort()),
          ),
        ),
      ],
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
    return Center(
      child: SizedBox.square(
        dimension: 24,
        child: CircularProgressIndicator(
          strokeWidth: 2,
          semanticsLabel: l10n.loading,
        ),
      ),
    );
  }
}
