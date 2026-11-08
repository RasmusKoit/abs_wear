import 'dart:async';
import 'dart:convert';

import 'package:abs_wear/app/view/crown_scrollbar.dart';
import 'package:abs_wear/l10n/l10n.dart';
import 'package:abs_wear/library/data/json_cache.dart';
import 'package:abs_wear/library/data/library_api.dart';
import 'package:abs_wear/player/player.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;

/// A podcast episode as listed on [EpisodesPage].
@immutable
class Episode {
  const Episode({
    required this.id,
    required this.title,
    required this.publishedAt,
  });

  factory Episode.fromJson(Map<String, dynamic> json) => Episode(
    id: json['id'] as String,
    title: json['title'] as String? ?? '',
    publishedAt: (json['publishedAt'] as num?)?.toInt() ?? 0,
  );

  final String id;
  final String title;

  /// Milliseconds since the epoch; 0 when unknown.
  final int publishedAt;

  Map<String, Object> toJson() => {
    'id': id,
    'title': title,
    'publishedAt': publishedAt,
  };
}

/// The episodes of one podcast, newest first.
class EpisodesPage extends StatefulWidget {
  const EpisodesPage({
    required this.serverUrl,
    required this.token,
    required this.user,
    required this.podcast,
    super.key,
  });

  final String serverUrl;
  final String token;
  final String user;
  final ShelfBook podcast;

  @override
  State<EpisodesPage> createState() => _EpisodesPageState();
}

class _EpisodesPageState extends State<EpisodesPage> {
  /// Fits a two-line title and the date at the largest text scale (1.3).
  static const double _rowHeight = 64;

  final _scrollController = ScrollController();
  List<Episode>? _episodes;
  bool _loading = false;
  Object? _error;

  /// The user's progress per episode id; empty until loaded (best effort,
  /// the list works without it).
  Map<String, ({double progress, bool finished})> _progress = const {};

  String get _cacheKey =>
      'episodes_${'${widget.serverUrl}|${widget.user}'.hashCode}_'
      '${widget.podcast.id}';

  @override
  void initState() {
    super.initState();
    unawaited(_showCachedThenLoad());
  }

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  Future<void> _showCachedThenLoad() async {
    final cached = await JsonCache.read(_cacheKey);
    if (!mounted) return;
    if (cached is List && _episodes == null) {
      setState(() {
        _episodes = cached
            .cast<Map<String, dynamic>>()
            .map(Episode.fromJson)
            .toList();
      });
    }
    await _load();
  }

  /// Bumped per progress request; older replies are dropped.
  int _progressRequest = 0;

  Future<void> _loadProgress() async {
    final request = ++_progressRequest;
    try {
      // /api/me holds progress for everything the account ever played, so
      // it is decoded and filtered off the UI isolate.
      final response = await http
          .get(
            Uri.parse('${widget.serverUrl}/api/me'),
            headers: {'Authorization': 'Bearer ${widget.token}'},
          )
          .timeout(const Duration(seconds: 20));
      if (response.statusCode != 200) return;
      final body = response.body;
      // A top-level function: a closure here would capture this State,
      // which can't be sent to another isolate.
      final progress = await compute(_episodeProgress, (
        body,
        widget.podcast.id,
      ));
      if (mounted && request == _progressRequest) {
        setState(() => _progress = progress);
      }
    } on Object catch (e) {
      debugPrint('Could not load episode progress: $e');
    }
  }

  Future<void> _load() async {
    if (_loading) return;
    unawaited(_loadProgress());
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final json =
          await getJson(
                '${widget.serverUrl}/api/items/${widget.podcast.id}'
                '?expanded=1',
                widget.token,
              )
              as Map<String, dynamic>;
      final media = json['media'] as Map<String, dynamic>? ?? const {};
      final episodes =
          (media['episodes'] as List? ?? const [])
              .cast<Map<String, dynamic>>()
              .map(Episode.fromJson)
              .toList()
            ..sort((a, b) => b.publishedAt.compareTo(a.publishedAt));
      if (!mounted) return;
      setState(() => _episodes = episodes);
      unawaited(
        JsonCache.write(_cacheKey, [for (final e in episodes) e.toJson()]),
      );
    } on Object catch (e) {
      if (!mounted) return;
      // Only an expired session concerns the pages below; a 404 here means
      // this podcast is gone, not the library.
      final result = e is ApiException ? e.result : null;
      if (result == LibraryResult.sessionExpired) {
        final route = ModalRoute.of(context);
        if (route != null && route.isCurrent) {
          Navigator.of(context).pop(result);
        }
        return;
      }
      setState(() => _error = e);
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _open(Episode episode) async {
    await Navigator.push(
      context,
      MaterialPageRoute<void>(
        builder: (context) => PlayerPage(
          token: widget.token,
          serverUrl: widget.serverUrl,
          libraryItemId: widget.podcast.id,
          episodeId: episode.id,
          user: widget.user,
        ),
      ),
    );
    // Show the progress just made, once the player has saved it.
    await Future<void>.delayed(const Duration(milliseconds: 500));
    await AudioPlayerController.lastClose;
    if (mounted) unawaited(_loadProgress());
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    final episodes = _episodes;
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
                widget.podcast.title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.bodyLarge,
              ),
            ),
          ),
        ),
        body: episodes == null || episodes.isEmpty
            ? Center(child: _status(l10n, theme, episodes))
            : ListView.builder(
                controller: _scrollController,
                padding: const EdgeInsets.fromLTRB(28, 4, 24, 48),
                itemExtent: _rowHeight,
                itemCount: episodes.length + (_error != null ? 1 : 0),
                itemBuilder: (context, index) {
                  if (index >= episodes.length) {
                    return InkWell(
                      onTap: () => unawaited(_load()),
                      child: Center(
                        child: Text(
                          l10n.offlineSavedList,
                          textAlign: TextAlign.center,
                          maxLines: 2,
                          style: theme.textTheme.labelSmall,
                        ),
                      ),
                    );
                  }
                  final episode = episodes[index];
                  return InkWell(
                    key: ValueKey(episode.id),
                    onTap: () => unawaited(_open(episode)),
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          episode.title,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.bodySmall,
                        ),
                        _details(context, l10n, theme, episode),
                      ],
                    ),
                  );
                },
              ),
      ),
    );
  }

  /// Date and progress: "Nov 8 · 30%", or a check when finished.
  Widget _details(
    BuildContext context,
    AppLocalizations l10n,
    ThemeData theme,
    Episode episode,
  ) {
    final style = theme.textTheme.labelSmall;
    final progress = _progress[episode.id];
    final date = episode.publishedAt > 0
        ? MaterialLocalizations.of(context).formatShortDate(
            DateTime.fromMillisecondsSinceEpoch(episode.publishedAt),
          )
        : null;
    final percent = progress != null && !progress.finished
        ? (progress.progress * 100).floor()
        : 0;
    return Row(
      children: [
        if (date != null) Text(date, style: style),
        if (progress?.finished ?? false) ...[
          if (date != null) const SizedBox(width: 4),
          Icon(
            Icons.check_circle_rounded,
            size: 12,
            color: theme.colorScheme.primary,
            semanticLabel: l10n.finished,
          ),
        ] else if (percent > 0)
          Text('${date != null ? ' · ' : ''}$percent%', style: style),
      ],
    );
  }

  Widget _status(
    AppLocalizations l10n,
    ThemeData theme,
    List<Episode>? episodes,
  ) {
    if (_error != null) {
      return InkWell(
        onTap: () => unawaited(_load()),
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Text(
            errorMessage(l10n, _error),
            textAlign: TextAlign.center,
            style: theme.textTheme.bodySmall,
          ),
        ),
      );
    }
    if (episodes == null || _loading) {
      return const CircularProgressIndicator();
    }
    return Text(l10n.noEpisodes, style: theme.textTheme.bodySmall);
  }
}

/// Progress per episode id of a podcast, from a /api/me reply.
Map<String, ({double progress, bool finished})> _episodeProgress(
  (String, String) bodyAndPodcastId,
) {
  final (body, podcastId) = bodyAndPodcastId;
  final me = jsonDecode(body) as Map<String, dynamic>;
  return {
    for (final p
        in (me['mediaProgress'] as List? ?? const [])
            .cast<Map<String, dynamic>>())
      if (p['libraryItemId'] == podcastId && p['episodeId'] is String)
        p['episodeId'] as String: (
          progress: (p['progress'] as num?)?.toDouble() ?? 0,
          finished: p['isFinished'] == true,
        ),
  };
}
