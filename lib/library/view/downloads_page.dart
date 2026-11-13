import 'dart:async';

import 'package:abs_wear/app/view/crown_scrollbar.dart';
import 'package:abs_wear/l10n/l10n.dart';
import 'package:abs_wear/library/data/downloads.dart';
import 'package:abs_wear/library/view/book_tile.dart';
import 'package:abs_wear/player/player.dart';
import 'package:flutter/material.dart';

/// Books and episodes on the watch; opens them even without a network.
class DownloadsPage extends StatefulWidget {
  const DownloadsPage({
    required this.serverUrl,
    required this.token,
    required this.user,
    super.key,
  });

  final String serverUrl;
  final String token;
  final String user;

  @override
  State<DownloadsPage> createState() => _DownloadsPageState();
}

class _DownloadsPageState extends State<DownloadsPage> {
  final _scrollController = ScrollController();
  List<DownloadedItem>? _items;

  @override
  void initState() {
    super.initState();
    DownloadManager.instance.addListener(_onDownloadsChanged);
    unawaited(_load());
  }

  @override
  void dispose() {
    DownloadManager.instance.removeListener(_onDownloadsChanged);
    _scrollController.dispose();
    super.dispose();
  }

  /// A download was queued or finished: a finished one is listed now.
  void _onDownloadsChanged() {
    if (!mounted) return;
    setState(() {});
    unawaited(_load());
  }

  Future<void> _load() async {
    List<DownloadedItem> items;
    try {
      items = await listDownloads(widget.serverUrl);
    } on Object catch (e) {
      debugPrint('Could not list downloads: $e');
      items = const [];
    }
    if (mounted) setState(() => _items = items);
  }

  Future<void> _open(DownloadedItem item) async {
    await Navigator.push(
      context,
      MaterialPageRoute<void>(
        builder: (context) => PlayerPage(
          token: widget.token,
          serverUrl: widget.serverUrl,
          libraryItemId: item.itemId,
          episodeId: item.episodeId,
          user: widget.user,
        ),
      ),
    );
    // The download may have been deleted from the player.
    if (mounted) unawaited(_load());
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    final items = _items;
    final jobs = DownloadManager.instance.jobs;
    return CrownScrollbar(
      controller: _scrollController,
      child: Scaffold(
        appBar: PreferredSize(
          preferredSize: const Size.fromHeight(40),
          child: AppBar(
            centerTitle: true,
            automaticallyImplyLeading: false,
            title: Text(l10n.downloads, style: theme.textTheme.bodyLarge),
          ),
        ),
        body: items == null
            ? Center(
                child: CircularProgressIndicator(semanticsLabel: l10n.loading),
              )
            : items.isEmpty && jobs.isEmpty
            ? Center(
                child: Text(l10n.noDownloads, style: theme.textTheme.bodySmall),
              )
            : ListView.builder(
                controller: _scrollController,
                padding: const EdgeInsets.fromLTRB(28, 4, 24, 48),
                itemExtent: BookTile.height,
                itemCount: jobs.length + items.length,
                itemBuilder: (context, index) {
                  // Running and queued downloads first.
                  if (index < jobs.length) {
                    final job = jobs[index];
                    return _ActiveDownloadTile(
                      key: ValueKey('job/${job.key}'),
                      job: job,
                    );
                  }
                  final item = items[index - jobs.length];
                  return _DownloadTile(
                    key: ValueKey('${item.itemId}/${item.episodeId}'),
                    item: item,
                    serverUrl: widget.serverUrl,
                    token: widget.token,
                    onTap: () => unawaited(_open(item)),
                  );
                },
              ),
      ),
    );
  }
}

class _DownloadTile extends StatelessWidget {
  const _DownloadTile({
    required this.item,
    required this.serverUrl,
    required this.token,
    required this.onTap,
    super.key,
  });

  final DownloadedItem item;
  final String serverUrl;
  final String token;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    const size = 44.0;
    final pixels = (size * MediaQuery.devicePixelRatioOf(context)).round();
    final coverFile = item.coverFile;
    return InkWell(
      onTap: onTap,
      child: Row(
        children: [
          if (coverFile != null)
            ClipRRect(
              borderRadius: BorderRadius.circular(4),
              child: Image.file(
                coverFile,
                width: size,
                height: size,
                cacheWidth: pixels,
                fit: BoxFit.cover,
                // Decorative: the title is read out next to it.
                excludeFromSemantics: true,
                errorBuilder: (_, _, _) =>
                    const Icon(Icons.book_rounded, size: size * 0.6),
              ),
            )
          else
            BookCover(
              serverUrl: serverUrl,
              token: token,
              bookId: item.itemId,
              size: size,
            ),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  item.title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.bodySmall,
                ),
                Text(
                  item.author,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.labelSmall,
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// A running or queued download; tapping its progress ring cancels it.
class _ActiveDownloadTile extends StatelessWidget {
  const _ActiveDownloadTile({required this.job, super.key});

  final DownloadJob job;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    return Row(
      children: [
        Expanded(
          child: Text(
            job.title,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: theme.textTheme.bodySmall,
          ),
        ),
        ValueListenableBuilder<double?>(
          valueListenable: job.progress,
          builder: (context, progress, _) => IconButton(
            tooltip: l10n.cancelDownload,
            onPressed: () => DownloadManager.instance.cancel(job.key),
            icon: SizedBox.square(
              dimension: 24,
              child: Stack(
                alignment: Alignment.center,
                children: [
                  // Spins while queued behind another book.
                  SizedBox.square(
                    dimension: 24,
                    child: CircularProgressIndicator(
                      value: progress,
                      strokeWidth: 2.5,
                      color: theme.colorScheme.secondary,
                      semanticsValue: progress == null
                          ? null
                          : '${(progress * 100).floor()}%',
                    ),
                  ),
                  Icon(
                    Icons.close_rounded,
                    size: 14,
                    color: theme.colorScheme.secondary,
                  ),
                ],
              ),
            ),
          ),
        ),
      ],
    );
  }
}
