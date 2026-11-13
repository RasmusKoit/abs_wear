import 'dart:async';

import 'package:abs_wear/app/continue_tile.dart';
import 'package:abs_wear/app/view/crown_scrollbar.dart';
import 'package:abs_wear/l10n/l10n.dart';
import 'package:abs_wear/library/data/downloads.dart';
import 'package:abs_wear/library/data/json_cache.dart';
import 'package:abs_wear/library/data/library_api.dart';
import 'package:abs_wear/library/view/book_tile.dart';
import 'package:abs_wear/library/view/browse_page.dart';
import 'package:abs_wear/library/view/downloads_page.dart';
import 'package:abs_wear/library/view/libraries_page.dart';
import 'package:abs_wear/player/player.dart';
import 'package:abs_wear/player/view/headphone_prompt.dart';
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

export 'package:abs_wear/library/data/library_api.dart'
    show LibraryResult, ShelfBook;

class LibraryPage extends StatefulWidget {
  const LibraryPage({
    required this.token,
    required this.serverUrl,
    required this.libraryId,
    required this.user,
    this.tileOpen,
    super.key,
  });
  final String token;
  final String serverUrl;
  final String libraryId;
  final String user;

  /// A tile tap the login page already took, opened once this page shows.
  final TileOpen? tileOpen;

  @override
  State<LibraryPage> createState() => _LibraryPageState();
}

class _LibraryPageState extends State<LibraryPage> {
  final _scrollController = ScrollController();
  StreamSubscription<void>? _tileOpens;

  /// Continue Listening; null until the cache or the server answered.
  List<ShelfBook>? _books;
  bool _loading = false;
  Object? _error;

  /// The server's libraries; null until the cache or the server answered.
  List<LibraryInfo>? _libraries;

  LibraryInfo? get _library {
    for (final l in _libraries ?? const <LibraryInfo>[]) {
      if (l.id == widget.libraryId) return l;
    }
    return null;
  }

  bool get _isPodcast => _library?.isPodcast ?? false;

  String get _userHash =>
      '${widget.serverUrl}|${widget.user}'.hashCode.toString();

  String get _cacheKey => 'shelf_${_userHash}_${widget.libraryId}';

  String get _librariesKey => 'libraries_$_userHash';

  @override
  void initState() {
    super.initState();
    DownloadManager.instance.addListener(_onDownloadsChanged);
    _tileOpens = ContinueTile.opens.listen((_) => unawaited(_openFromTile()));
    unawaited(_openFromTile(widget.tileOpen));
    unawaited(ContinueTile.showShelf(_cacheKey));
    unawaited(_showCachedThenRefresh());
  }

  @override
  void dispose() {
    DownloadManager.instance.removeListener(_onDownloadsChanged);
    unawaited(_tileOpens?.cancel());
    _scrollController.dispose();
    super.dispose();
  }

  /// The saved shelf shows instantly (also offline); the server's answer
  /// replaces it when it arrives.
  Future<void> _showCachedThenRefresh() async {
    final libraries = await JsonCache.read(_librariesKey);
    if (libraries is List && mounted && _libraries == null) {
      setState(() {
        _libraries = libraries
            .cast<Map<String, dynamic>>()
            .map(LibraryInfo.fromJson)
            .toList();
      });
    }
    // Independent of the shelf, so the title and switcher show even when
    // Continue Listening fails.
    unawaited(_refreshLibraries());
    unawaited(_refreshDownloads());
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
        JsonCache.write(_cacheKey, [
          for (final b in books) b.toCache(),
        ]).then((_) => ContinueTile.refresh()),
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

  /// Library names and kinds, for the title and the library switcher.
  Future<void> _refreshLibraries() async {
    try {
      final libraries = await fetchLibraries(widget.serverUrl, widget.token);
      if (!mounted) return;
      setState(() => _libraries = libraries);
      unawaited(
        JsonCache.write(_librariesKey, [for (final l in libraries) l.toJson()]),
      );
    } on Object catch (e) {
      debugPrint('Could not load libraries: $e');
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

  /// Whether anything is downloaded (shows the Downloads entry, which also
  /// works offline).
  bool _hasDownloads = false;

  /// A download was queued or finished, maybe from a closed player.
  void _onDownloadsChanged() {
    if (!mounted) return;
    setState(() {});
    unawaited(_refreshDownloads());
  }

  Future<void> _refreshDownloads() async {
    try {
      final items = await listDownloads(widget.serverUrl);
      if (mounted) setState(() => _hasDownloads = items.isNotEmpty);
    } on Object catch (e) {
      debugPrint('Could not list downloads: $e');
    }
  }

  Future<void> _openDownloads() async {
    await Navigator.push(
      context,
      MaterialPageRoute<void>(
        builder: (context) => DownloadsPage(
          serverUrl: widget.serverUrl,
          token: widget.token,
          user: widget.user,
        ),
      ),
    );
    await Future<void>.delayed(const Duration(milliseconds: 500));
    await NowPlaying.settled();
    if (!mounted) return;
    unawaited(_refreshDownloads());
    unawaited(_refresh());
  }

  /// Opens the book a tap on the tile asked for, on top of this page.
  Future<void> _openFromTile([TileOpen? taken]) async {
    // Always after an await: initState must not read the route.
    final open = await (taken != null
        ? Future.value(taken)
        : ContinueTile.take());
    if (open == null || !mounted || _closing) return;
    final route = ModalRoute.of(context);
    if (route == null) return;
    Navigator.of(context).popUntil((r) => r == route);
    await _openBook(
      ShelfBook(id: open.id, title: '', author: '', episodeId: open.episodeId),
    );
  }

  Future<void> _openBook(ShelfBook book) async {
    await Navigator.push(
      context,
      MaterialPageRoute<void>(
        builder: (context) => PlayerPage(
          token: widget.token,
          serverUrl: widget.serverUrl,
          libraryItemId: book.id,
          episodeId: book.episodeId,
          user: widget.user,
        ),
      ),
    );
    // Progress changed while listening; reload once it was sent.
    await Future<void>.delayed(const Duration(milliseconds: 500));
    await NowPlaying.settled();
    if (!mounted) return;
    unawaited(_refresh());
    unawaited(_refreshDownloads());
  }

  /// Back to the book playing in the background.
  Future<void> _openNowPlaying(AudioPlayerController playing) async {
    await Navigator.push(
      context,
      MaterialPageRoute<void>(
        builder: (context) => PlayerPage(
          token: playing.token,
          serverUrl: playing.serverUrl,
          libraryItemId: playing.libraryItemId,
          episodeId: playing.episodeId,
          user: playing.user,
        ),
      ),
    );
    await Future<void>.delayed(const Duration(milliseconds: 500));
    await NowPlaying.settled();
    if (!mounted) return;
    unawaited(_refresh());
    unawaited(_refreshDownloads());
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
          isPodcast: _isPodcast,
        ),
      ),
    );
    if (!mounted) return;
    if (result != null) {
      _close(result);
      return;
    }
    // A book opened from the list may still be saving its position.
    await NowPlaying.settled();
    if (!mounted) return;
    unawaited(_refresh());
    // A book may have been downloaded or deleted from the list.
    unawaited(_refreshDownloads());
  }

  Future<void> _switchLibrary() async {
    final libraries = _libraries;
    if (libraries == null) return;
    final id = await Navigator.push(
      context,
      MaterialPageRoute<String>(
        builder: (context) =>
            LibrariesPage(libraries: libraries, currentId: widget.libraryId),
      ),
    );
    if (id == null || id == widget.libraryId || !mounted) return;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('defaultLibraryId', id);
    // Also kept across a session expiry, for the next login.
    await prefs.setString(
      'pickedLibrary',
      '${widget.serverUrl}\n${widget.user}\n$id',
    );
    _close(LibraryResult.switchLibrary);
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    return CrownScrollbar(
      controller: _scrollController,
      child: Scaffold(
        appBar: PreferredSize(
          preferredSize: const Size.fromHeight(40),
          child: AppBar(
            centerTitle: true,
            // Inset so the ellipsis stays inside the round screen.
            title: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 40),
              child: Text(
                _library?.name ?? l10n.library,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.bodyLarge,
              ),
            ),
            automaticallyImplyLeading: false,
          ),
        ),
        body: SingleChildScrollView(
          controller: _scrollController,
          padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 8),
          child: Column(
            children: [
              ListenableBuilder(
                listenable: NowPlaying.instance,
                builder: (context, _) {
                  final playing = NowPlaying.instance.controller;
                  // Only this account's book (a logout closes it anyway).
                  if (playing == null ||
                      playing.serverUrl != widget.serverUrl ||
                      playing.user != widget.user) {
                    return const SizedBox.shrink();
                  }
                  return NowPlayingCard(
                    controller: playing,
                    onTap: () => unawaited(_openNowPlaying(playing)),
                  );
                },
              ),
              Text(l10n.continueListening),
              ..._shelf(l10n, theme),
              Card(
                child: ListTile(
                  title: Text(
                    _isPodcast ? l10n.allPodcasts : l10n.allBooks,
                    style: theme.textTheme.bodySmall,
                  ),
                  trailing: const Icon(Icons.library_books_rounded),
                  onTap: () => unawaited(_browse()),
                ),
              ),
              if (_hasDownloads || DownloadManager.instance.jobs.isNotEmpty)
                Card(
                  child: ListTile(
                    title: Text(
                      l10n.downloads,
                      style: theme.textTheme.bodySmall,
                    ),
                    trailing: const Icon(Icons.download_done_rounded),
                    onTap: () => unawaited(_openDownloads()),
                  ),
                ),
              if ((_libraries?.length ?? 0) > 1)
                Card(
                  child: ListTile(
                    title: Text(
                      l10n.libraries,
                      style: theme.textTheme.bodySmall,
                    ),
                    trailing: const Icon(Icons.swap_horiz_rounded),
                    onTap: () => unawaited(_switchLibrary()),
                  ),
                ),
              Card(
                child: ListTile(
                  title: Text(l10n.refresh, style: theme.textTheme.bodySmall),
                  trailing: _loading
                      ? SizedBox.square(
                          dimension: 20,
                          child: CircularProgressIndicator(
                            strokeWidth: 2,
                            semanticsLabel: l10n.loading,
                          ),
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
          Padding(
            padding: const EdgeInsets.all(16),
            child: CircularProgressIndicator(semanticsLabel: l10n.loading),
          ),
      ];
    }
    return [
      // Showing the saved shelf because the server can't be reached. The
      // banner says "Tap to retry", as on the other lists.
      if (_error != null)
        InkWell(
          onTap: () => unawaited(_refresh()),
          child: message(l10n.offlineSavedList),
        ),
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
    // The ink inside the card: the card is its own semantics node, so an
    // InkWell around it was a tap target without a label, and the title
    // and author were read as separate, untappable items.
    return Card(
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
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

/// The book open in the background: tap to open it, or play/pause here.
class NowPlayingCard extends StatelessWidget {
  const NowPlayingCard({
    required this.controller,
    required this.onTap,
    super.key,
  });

  final AudioPlayerController controller;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    return ListenableBuilder(
      listenable: controller,
      builder: (context, _) => Card(
        clipBehavior: Clip.antiAlias,
        child: ListTile(
          contentPadding: const EdgeInsets.only(left: 12, right: 4),
          title: Text(
            controller.isLoaded ? controller.bookTitle : l10n.loading,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: theme.textTheme.bodySmall,
          ),
          onTap: onTap,
          trailing: StreamBuilder<bool>(
            stream: controller.player.playingStream,
            initialData: controller.player.playing,
            builder: (context, snapshot) {
              final playing = snapshot.data ?? false;
              return IconButton(
                tooltip: playing ? l10n.pause : l10n.play,
                icon: Icon(
                  playing ? Icons.pause_rounded : Icons.play_arrow_rounded,
                ),
                onPressed: controller.isLoaded
                    ? () => unawaited(togglePlayChecked(context, controller))
                    : null,
              );
            },
          ),
        ),
      ),
    );
  }
}
