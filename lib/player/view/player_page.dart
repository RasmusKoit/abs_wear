import 'dart:async';

import 'package:abs_wear/player/player.dart';
import 'package:flutter/material.dart';
import 'package:rotary_scrollbar/rotary_scrollbar.dart';

class PlayerPage extends StatefulWidget {
  const PlayerPage({
    required this.libraryItemId,
    required this.serverUrl,
    required this.token,
    super.key,
  });
  final String libraryItemId;
  final String serverUrl;
  final String token;

  @override
  State<PlayerPage> createState() => _PlayerPageState();
}

class _PlayerPageState extends State<PlayerPage> {
  final PageController _pageController = PageController();
  final AudioPlayerController _playerController = AudioPlayerController();
  late Timer? _syncTimer;

  @override
  void initState() {
    super.initState();
    asyncInitState();
  }

  Future<void> asyncInitState() async {
    await _playerController.setupPlayer(
      widget.libraryItemId,
      widget.serverUrl,
      widget.token,
    );
    _pageController.jumpTo(0.1);
    // setup timer to sync player state with server
    _syncTimer = Timer.periodic(const Duration(minutes: 1), (timer) {
      _playerController.syncOpenSession();
    });
  }

  @override
  void dispose() {
    asyncDispose();
    _syncTimer?.cancel();
    _playerController.player.dispose();
    _playerController.dispose();
    _pageController.dispose();
    super.dispose();
  }

  Future<void> asyncDispose() async {
    await _playerController.syncOpenSession(close: true);
  }

  @override
  Widget build(BuildContext context) {
    return RotaryScrollWrapper(
      rotaryScrollbar: RotaryScrollbar(
        width: 2,
        padding: 1,
        hasHapticFeedback: false,
        autoHide: false,
        controller: _pageController,
      ),
      child: Scaffold(
        body: Row(
          children: <Widget>[
            Expanded(
              child: PageView(
                scrollDirection: Axis.vertical,
                controller: _pageController,
                children: [
                  PlayerViewPage(
                    playerController: _playerController,
                  ),
                  ControlViewPage(
                    playerController: _playerController,
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
