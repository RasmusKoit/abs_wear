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
  final AudioPlayerController _playerController = AudioPlayerController();
  Timer? _syncTimer;

  @override
  void initState() {
    super.initState();
    unawaited(_init());
  }

  Future<void> _init() async {
    _playerController.onPlaybackError = (message) =>
        unawaited(showToast(message));
    final ok = await _playerController.setupPlayer(
      widget.libraryItemId,
      widget.serverUrl,
      widget.token,
      userName: widget.user,
      episodeId: widget.episodeId,
    );
    if (!mounted) return;
    final l10n = context.l10n;
    if (!ok) {
      unawaited(showToast(l10n.couldNotStartPlayback));
      // Remove this page even if a dialog is open on top of it.
      final route = ModalRoute.of(context);
      if (route != null) Navigator.of(context).removeRoute(route);
      return;
    }
    if (_playerController.isOffline) {
      unawaited(showToast(l10n.playingOffline));
    }
    // Keep the server's progress in sync while the player is open.
    // Offline, this saves progress on the watch instead.
    _syncTimer = Timer.periodic(
      const Duration(minutes: 1),
      (_) => unawaited(_playerController.periodicSync()),
    );
  }

  @override
  void dispose() {
    _syncTimer?.cancel();
    // Saves the final position, then releases the player.
    unawaited(_playerController.close());
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
