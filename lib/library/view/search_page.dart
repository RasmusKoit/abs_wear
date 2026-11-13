import 'dart:async';

import 'package:abs_wear/app/view/crown_scrollbar.dart';
import 'package:abs_wear/l10n/l10n.dart';
import 'package:abs_wear/library/data/library_api.dart';
import 'package:abs_wear/library/view/book_tile.dart';
import 'package:abs_wear/library/view/episodes_page.dart';
import 'package:abs_wear/player/player.dart';
import 'package:flutter/material.dart';

/// Opens [book]: the player for a book, the episode list for a podcast.
/// Returns why the episode list closed the library, if it did.
Future<LibraryResult?> openShelfBook(
  BuildContext context,
  ShelfBook book, {
  required String serverUrl,
  required String token,
  required String user,
}) async {
  if (!book.isPodcast) {
    await Navigator.push(
      context,
      MaterialPageRoute<void>(
        builder: (context) => PlayerPage(
          token: token,
          serverUrl: serverUrl,
          libraryItemId: book.id,
          user: user,
        ),
      ),
    );
    return null;
  }
  return await Navigator.push(
    context,
    MaterialPageRoute<LibraryResult>(
      builder: (context) => EpisodesPage(
        serverUrl: serverUrl,
        token: token,
        user: user,
        podcast: book,
      ),
    ),
  );
}

/// Finds books (or podcasts) by title with the server's library search.
/// The field opens the watch keyboard, which also offers voice input.
class SearchPage extends StatefulWidget {
  const SearchPage({
    required this.serverUrl,
    required this.token,
    required this.libraryId,
    required this.user,
    super.key,
  });

  final String serverUrl;
  final String token;
  final String libraryId;
  final String user;

  @override
  State<SearchPage> createState() => _SearchPageState();
}

class _SearchPageState extends State<SearchPage> {
  final _scrollController = ScrollController();
  final _queryController = TextEditingController();

  /// Null until the first search finishes.
  List<ShelfBook>? _results;
  bool _loading = false;
  Object? _error;

  /// Bumped per search; replies for older searches are dropped.
  int _generation = 0;

  @override
  void dispose() {
    _scrollController.dispose();
    _queryController.dispose();
    super.dispose();
  }

  Future<void> _search() async {
    final query = _queryController.text.trim();
    if (query.isEmpty) return;
    final generation = ++_generation;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final results = await searchLibrary(
        widget.serverUrl,
        widget.token,
        widget.libraryId,
        query,
      );
      if (!mounted || generation != _generation) return;
      setState(() => _results = results);
    } on Object catch (e) {
      if (!mounted || generation != _generation) return;
      final result = e is ApiException ? e.result : null;
      if (result != null) {
        _close(result);
        return;
      }
      setState(() => _error = e);
    } finally {
      if (mounted && generation == _generation) {
        setState(() => _loading = false);
      }
    }
  }

  void _close(LibraryResult result) {
    final route = ModalRoute.of(context);
    if (route != null && route.isCurrent) Navigator.of(context).pop(result);
  }

  Future<void> _open(ShelfBook book) async {
    final result = await openShelfBook(
      context,
      book,
      serverUrl: widget.serverUrl,
      token: widget.token,
      user: widget.user,
    );
    if (result != null && mounted) _close(result);
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    final results = _results;
    Widget message(String text) => Padding(
      padding: const EdgeInsets.all(8),
      child: Text(
        text,
        textAlign: TextAlign.center,
        style: theme.textTheme.labelSmall,
      ),
    );
    return CrownScrollbar(
      controller: _scrollController,
      child: Scaffold(
        appBar: PreferredSize(
          preferredSize: const Size.fromHeight(40),
          child: AppBar(
            centerTitle: true,
            automaticallyImplyLeading: false,
            title: Text(l10n.search, style: theme.textTheme.bodyLarge),
          ),
        ),
        body: ListView(
          controller: _scrollController,
          // Round screen: keep rows away from the clipped corners.
          padding: const EdgeInsets.fromLTRB(28, 4, 24, 48),
          children: [
            TextField(
              controller: _queryController,
              autofocus: true,
              style: theme.textTheme.labelSmall,
              scrollPadding: const EdgeInsets.all(8),
              decoration: InputDecoration(
                labelText: l10n.searchLabel,
                labelStyle: theme.textTheme.labelSmall,
                suffixIcon: IconButton(
                  icon: const Icon(Icons.search_rounded),
                  tooltip: l10n.search,
                  onPressed: () => unawaited(_search()),
                ),
              ),
              textInputAction: TextInputAction.search,
              onSubmitted: (_) => unawaited(_search()),
            ),
            const SizedBox(height: 8),
            if (_loading)
              Center(
                child: SizedBox.square(
                  dimension: 24,
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    semanticsLabel: l10n.loading,
                  ),
                ),
              )
            else if (_error != null)
              InkWell(
                onTap: () => unawaited(_search()),
                child: message(errorMessage(l10n, _error)),
              )
            else if (results != null && results.isEmpty)
              message(l10n.noMatches)
            else if (results != null)
              for (final book in results)
                BookTile(
                  key: ValueKey(book.id),
                  book: book,
                  serverUrl: widget.serverUrl,
                  token: widget.token,
                  onTap: () => unawaited(_open(book)),
                ),
          ],
        ),
      ),
    );
  }
}
