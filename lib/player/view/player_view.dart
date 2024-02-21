import 'dart:async';

import 'package:abs_wear/player/components/scrolling_text.dart';
import 'package:abs_wear/player/components/time_left_widget.dart';
import 'package:abs_wear/player/darts/audio_player.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:just_audio/just_audio.dart';

class PlayerViewPage extends StatefulWidget {
  const PlayerViewPage({required this.playerController, super.key});

  final AudioPlayerController playerController;

  @override
  State<PlayerViewPage> createState() => _PlayerViewPageState();
}

class _PlayerViewPageState extends State<PlayerViewPage> {
  final ValueNotifier<String> _timeLeftNotifier = ValueNotifier<String>('');
  StreamSubscription<Duration>? _positionSubscription;
  String _title = '';
  String _chapterName = '';
  bool isPlaying = false;

  @override
  void initState() {
    super.initState();
    _positionSubscription =
        widget.playerController.player.positionStream.listen((event) {
      _updateTitleAndChapterName();
      _timeLeftNotifier.value = widget.playerController.getTimeLeft();
      widget.playerController.updateChapterNameAndDuration(_timeLeftNotifier);
      isPlaying = widget.playerController.player.playing;
    });
  }

  @override
  void dispose() {
    _positionSubscription?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Stack(
      children: <Widget>[
        SizedBox.expand(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              const SizedBox(
                height: 8,
              ),
              _buildScrollingText(
                theme.textTheme.labelMedium!,
                widget.playerController.bookTitle,
                35,
                2.5,
              ),
              _buildScrollingText(
                theme.textTheme.labelSmall!,
                widget.playerController.chapterName,
                30,
                0,
              ),
              _buildPlaybackControls(),
              _buildSeekButtons(),
              _buildTimeLeftWidget(theme.textTheme.labelSmall!),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildScrollingText(
    TextStyle textStyle,
    String text,
    double horizontalPadding,
    double verticalPadding,
  ) {
    return Padding(
      padding: EdgeInsets.symmetric(
        horizontal: horizontalPadding,
        vertical: verticalPadding,
      ),
      child: ScrollingText(
        text: text,
        style: textStyle,
      ),
    );
  }

  Widget _buildPlaybackControls() {
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        IconButton(
          icon: const Icon(Icons.skip_previous),
          onPressed: () {
            widget.playerController.seekToPrevious();
            _updateTitleAndChapterName();
          }, //seekToPrevious,
        ),
        _buildPlayPauseButton(),
        IconButton(
          icon: const Icon(Icons.skip_next),
          onPressed: () {
            widget.playerController.seekToNext();
            _updateTitleAndChapterName();
          }, // seekToNext,
        ),
      ],
    );
  }

  Widget _buildPlayPauseButton() {
    return StreamBuilder<ProcessingState>(
      stream: widget.playerController.player.processingStateStream,
      builder: (context, snapshot) {
        final processingState = snapshot.data;
        if (kDebugMode) {
          print('Processing state: $processingState');
        }
        if ((processingState == ProcessingState.ready ||
                processingState == ProcessingState.idle) &&
            !widget.playerController.isDownloading) {
          return IconButton(
            icon: Icon(
              isPlaying ? Icons.pause : Icons.play_arrow,
            ),
            onPressed: () async {
              if (isPlaying) {
                setState(() {
                  isPlaying = false;
                });
                unawaited(widget.playerController.player.pause());
              } else {
                setState(() {
                  isPlaying = true;
                });
                unawaited(widget.playerController.player.play());
              }
            },
          );
        } else {
          return const SizedBox(
            height: 48,
            width: 48,
            child: Padding(
              padding: EdgeInsets.all(12),
              child: CircularProgressIndicator(
                strokeWidth: 2.5,
                color: Colors.white,
              ),
            ),
          );
        }
      },
    );
  }

  Widget _buildSeekButtons() {
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        IconButton(
          icon: const Icon(Icons.replay_10_rounded),
          onPressed: () {
            widget.playerController.seekTo(
              -10 + widget.playerController.player.position.inSeconds,
            );
            _updateTitleAndChapterName();
          },
        ),
        IconButton(
          icon: const Icon(Icons.forward_10_rounded),
          onPressed: () {
            widget.playerController.seekTo(
              10 + widget.playerController.player.position.inSeconds,
            );
            _updateTitleAndChapterName();
          },
        ),
      ],
    );
  }

  Widget _buildTimeLeftWidget(TextStyle textStyle) {
    return ValueListenableBuilder<String>(
      valueListenable: _timeLeftNotifier,
      builder: (context, value, child) {
        return TimeLeftWidget(
          timeLeft: value,
          style: textStyle,
        );
      },
    );
  }

  void _updateTitleAndChapterName() {
    widget.playerController.updateChapterNameAndDuration(_timeLeftNotifier);
    if (_title != widget.playerController.bookTitle) {
      setState(() {
        _title = widget.playerController.bookTitle;
      });
    }

    if (_chapterName != widget.playerController.chapterName) {
      setState(() {
        _chapterName = widget.playerController.chapterName;
      });
    }
  }
}
