import 'dart:async';

import 'package:abs_wear/app/toast.dart';
import 'package:abs_wear/app/view/crown_scrollbar.dart';
import 'package:abs_wear/app/view/overscroll_to_previous_page.dart';
import 'package:abs_wear/l10n/l10n.dart';
import 'package:abs_wear/player/player.dart';
import 'package:flutter/material.dart';

class PlayerPage extends StatefulWidget {
  const PlayerPage({
    required this.libraryItemId,
    required this.serverUrl,
    required this.token,
    required this.user,
    this.episodeId,
    super.key,
  });
  final String libraryItemId;

  /// The episode to play when [libraryItemId] is a podcast.
  final String? episodeId;
  final String serverUrl;
  final String token;

  /// Logged-in user, to keep offline progress per account.
  final String user;

  @override
  State<PlayerPage> createState() => _PlayerPageState();
}

class _PlayerPageState extends State<PlayerPage> {
  final PageController _pageController = PageController();
  late final AudioPlayerController _playerController;

  @override
  void initState() {
    super.initState();
    // Attaches to the book when it is the one already playing.
    final opened = NowPlaying.instance.open(
      libraryItemId: widget.libraryItemId,
      serverUrl: widget.serverUrl,
      token: widget.token,
      user: widget.user,
      episodeId: widget.episodeId,
    );
    _playerController = opened.controller..onPlaybackError = _onPlaybackError;
    unawaited(_init(opened.ready, created: opened.created));
  }

  void _onPlaybackError() {
    if (mounted) unawaited(showToast(context.l10n.playbackError));
  }

  Future<void> _init(Future<bool> ready, {required bool created}) async {
    final ok = await ready;
    if (!mounted) return;
    final l10n = context.l10n;
    if (!ok) {
      unawaited(showToast(l10n.couldNotStartPlayback));
      // Remove this page even if a dialog is open on top of it.
      final route = ModalRoute.of(context);
      if (route != null) Navigator.of(context).removeRoute(route);
      return;
    }
    if (created && _playerController.isOffline) {
      unawaited(showToast(l10n.playingOffline));
    }
  }

  @override
  void dispose() {
    // Playback and downloads go on; only this page's toasts stop.
    if (_playerController.onPlaybackError == _onPlaybackError) {
      _playerController.onPlaybackError = null;
    }
    _pageController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return CrownScrollbar(
      controller: _pageController,
      child: Scaffold(
        body: PageView(
          scrollDirection: Axis.vertical,
          controller: _pageController,
          children: [
            PlayerViewPage(playerController: _playerController),
            OverscrollToPreviousPage(
              controller: _pageController,
              child: ControlViewPage(playerController: _playerController),
            ),
          ],
        ),
      ),
    );
  }
}
