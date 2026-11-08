import 'dart:async';

import 'package:abs_wear/ambient_mode/ambient_mode.dart';
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
                  builder: (context, _, _) => _content(theme),
                )
              : StreamBuilder<double>(
                  stream: controller.bookPositionStream,
                  builder: (context, _) => _content(theme),
                ),
        );
      },
    );
  }

  Widget _content(ThemeData theme) {
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
              icon: const Icon(Icons.skip_previous),
              onPressed: () => unawaited(controller.seekToPreviousChapter()),
            ),
            _PlayPauseButton(controller: controller),
            IconButton(
              icon: const Icon(Icons.skip_next),
              onPressed: () => unawaited(controller.seekToNextChapter()),
            ),
          ],
        ),
        Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            IconButton(
              icon: const Icon(Icons.replay_10_rounded),
              onPressed: () => unawaited(controller.seekRelative(-10)),
            ),
            IconButton(
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

class _PlayPauseButton extends StatelessWidget {
  const _PlayPauseButton({required this.controller});

  final AudioPlayerController controller;

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<PlayerState>(
      stream: controller.player.playerStateStream,
      builder: (context, snapshot) {
        final state = snapshot.data;
        final busy =
            controller.isDownloading ||
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
          icon: Icon(playing ? Icons.pause : Icons.play_arrow),
          onPressed: () => unawaited(controller.togglePlayPause()),
        );
      },
    );
  }
}
