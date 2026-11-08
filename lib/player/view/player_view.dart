import 'dart:async';

import 'package:abs_wear/ambient_mode/ambient_mode.dart';
import 'package:abs_wear/app/app_visibility.dart';
import 'package:abs_wear/l10n/l10n.dart';
import 'package:abs_wear/player/components/scrolling_text.dart';
import 'package:abs_wear/player/components/time_left_widget.dart';
import 'package:abs_wear/player/darts/audio_player.dart';
import 'package:flutter/material.dart';
import 'package:just_audio/just_audio.dart';

class PlayerViewPage extends StatelessWidget {
  const PlayerViewPage({required this.playerController, super.key});

  final AudioPlayerController playerController;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final controller = playerController;
    // Rebuild when the session loads/reloads and as playback moves, so the
    // title and chapter show before playback starts.
    return ListenableBuilder(
      listenable: controller,
      builder: (context, _) {
        if (!controller.isLoaded) {
          return const Center(child: CircularProgressIndicator());
        }
        final ambient = AmbientModeListener.instance;
        return ValueListenableBuilder<bool>(
          valueListenable: ambient,
          builder: (context, isAmbient, _) => isAmbient
              // Ambient: redraw only on the system's (minutely) updates.
              ? ValueListenableBuilder<int>(
                  valueListenable: ambient.updates,
                  builder: (context, tick, _) =>
                      _ambientContent(theme, tick, ambient.burnInProtection),
                )
              : PlaybackTicker(
                  playing: controller.player.playerStateStream.map(
                    (state) => state.playing,
                  ),
                  changes: controller.player.playbackEventStream,
                  builder: (context) => _content(context, theme),
                ),
        );
      },
    );
  }

  /// Always-on variant: no buttons (few lit pixels), minutes only (it
  /// redraws about once a minute), shifted a little on each update when
  /// the display needs burn-in protection.
  Widget _ambientContent(ThemeData theme, int tick, bool burnIn) {
    final controller = playerController;
    final left = controller.timeLeft;
    final shift = burnIn ? Offset((tick % 3 - 1) * 4, (tick % 2) * 4) : null;
    final content = Column(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 35),
          child: ScrollingText(
            text: controller.bookTitle,
            style: theme.textTheme.labelMedium!,
          ),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 30),
          child: ScrollingText(
            text: controller.chapterName,
            style: theme.textTheme.labelSmall!,
          ),
        ),
        const SizedBox(height: 12),
        Text(
          '${left.inHours.toString().padLeft(2, '0')}:'
          '${(left.inMinutes % 60).toString().padLeft(2, '0')}',
          style: theme.textTheme.labelSmall,
        ),
      ],
    );
    return shift == null
        ? content
        : Transform.translate(offset: shift, child: content);
  }

  Widget _content(BuildContext context, ThemeData theme) {
    final controller = playerController;
    return Column(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        const SizedBox(height: 8),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 35, vertical: 2.5),
          child: ScrollingText(
            text: controller.bookTitle,
            style: theme.textTheme.labelMedium!,
          ),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 30),
          child: ScrollingText(
            text: controller.chapterName,
            style: theme.textTheme.labelSmall!,
          ),
        ),
        Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            IconButton(
              tooltip: context.l10n.previousChapter,
              icon: const Icon(Icons.skip_previous),
              onPressed: () => unawaited(controller.seekToPreviousChapter()),
            ),
            _PlayPauseButton(controller: controller),
            IconButton(
              tooltip: context.l10n.nextChapter,
              icon: const Icon(Icons.skip_next),
              onPressed: () => unawaited(controller.seekToNextChapter()),
            ),
          ],
        ),
        Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            IconButton(
              tooltip: context.l10n.back10,
              icon: const Icon(Icons.replay_10_rounded),
              onPressed: () => unawaited(controller.seekRelative(-10)),
            ),
            IconButton(
              tooltip: context.l10n.forward10,
              icon: const Icon(Icons.forward_10_rounded),
              onPressed: () => unawaited(controller.seekRelative(10)),
            ),
          ],
        ),
        TimeLeftWidget(
          timeLeft: formatDuration(controller.timeLeft),
          style: theme.textTheme.labelSmall!,
        ),
      ],
    );
  }
}

/// Rebuilds [builder] once a second while [playing] is true and the app is
/// on screen, and on every [changes] event (play, pause, seek, track
/// change). Paused or hidden, it draws nothing new. The streams are read
/// once, when the widget is first built.
@visibleForTesting
class PlaybackTicker extends StatefulWidget {
  const PlaybackTicker({
    required this.playing,
    required this.changes,
    required this.builder,
    this.period = const Duration(seconds: 1),
    super.key,
  });

  final Stream<bool> playing;
  final Stream<Object?> changes;
  final WidgetBuilder builder;
  final Duration period;

  @override
  State<PlaybackTicker> createState() => _PlaybackTickerState();
}

class _PlaybackTickerState extends State<PlaybackTicker> {
  final AppVisibility _visibility = AppVisibility.instance;
  late final StreamSubscription<bool> _playingSub;
  late final StreamSubscription<Object?> _changesSub;
  Timer? _timer;
  bool _playing = false;

  @override
  void initState() {
    super.initState();
    _visibility
      ..ensureInitialized()
      ..addListener(_update);
    _playingSub = widget.playing.listen((playing) {
      _playing = playing;
      _update();
    });
    _changesSub = widget.changes.listen(
      (_) => _refresh(),
      onError: (Object _) {},
    );
  }

  void _refresh() {
    if (mounted) setState(() {});
  }

  void _update() {
    if (_playing && _visibility.value) {
      _timer ??= Timer.periodic(widget.period, (_) => _refresh());
    } else {
      _timer?.cancel();
      _timer = null;
    }
    _refresh();
  }

  @override
  void dispose() {
    _visibility.removeListener(_update);
    _timer?.cancel();
    unawaited(_playingSub.cancel());
    unawaited(_changesSub.cancel());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.builder(context);
}

class _PlayPauseButton extends StatelessWidget {
  const _PlayPauseButton({required this.controller});

  final AudioPlayerController controller;

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<PlayerState>(
      stream: controller.player.playerStateStream,
      builder: (context, snapshot) {
        final state = snapshot.data;
        // Only the player's own state: playback stays controllable while a
        // download runs in the background.
        final busy =
            state?.processingState == ProcessingState.loading ||
            state?.processingState == ProcessingState.buffering;
        if (busy) {
          return const SizedBox.square(
            dimension: 48,
            child: Padding(
              padding: EdgeInsets.all(12),
              child: CircularProgressIndicator(strokeWidth: 2.5),
            ),
          );
        }
        final playing = state?.playing ?? false;
        return IconButton(
          tooltip: playing ? context.l10n.pause : context.l10n.play,
          icon: Icon(playing ? Icons.pause : Icons.play_arrow),
          onPressed: () => unawaited(controller.togglePlayPause()),
        );
      },
    );
  }
}
