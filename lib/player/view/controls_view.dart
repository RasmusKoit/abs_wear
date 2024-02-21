import 'dart:async';

import 'package:abs_wear/l10n/l10n.dart';
import 'package:abs_wear/player/darts/audio_player.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:just_audio/just_audio.dart';
import 'package:volume_controller/volume_controller.dart';

class ControlViewPage extends StatefulWidget {
  const ControlViewPage({required this.playerController, super.key});
  final AudioPlayerController playerController;

  @override
  State<ControlViewPage> createState() => _ControlViewPageState();
}

class _ControlViewPageState extends State<ControlViewPage> {
  double _getVolume = 0;
  String localMediaFilePath = '';
  bool isBuffering = true;
  bool isDownloading = false;

  @override
  void initState() {
    super.initState();
    widget.playerController.player.processingStateStream.listen((event) {
      if (kDebugMode) {
        print(localMediaFilePath);
      }
      if (event == ProcessingState.buffering) {
        if (kDebugMode) {
          print('Buffering');
        }
        if (mounted) {
          setState(() {
            isBuffering = true;
          });
        }
      } else {
        if (kDebugMode) {
          print('Not buffering');
        }
        if (mounted) {
          setState(() {
            isBuffering = false;
          });
        }
      }
    });
    _init();
  }

  Future<void> _init() async {
    _getVolume = await VolumeController().getVolume();

    final newLocalMediaFilePath =
        await widget.playerController.getLocalFilePath(getAudioFile: true);
    final getCurrentDownloading = widget.playerController.isDownloading;
    if (mounted) {
      setState(() {
        localMediaFilePath = newLocalMediaFilePath;
        isDownloading = getCurrentDownloading;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    return Stack(
      children: <Widget>[
        SizedBox.expand(
          child: Scaffold(
            appBar: AppBar(
              centerTitle: true,
              automaticallyImplyLeading: false,
              title: Text(
                l10n.controls,
                style: theme.textTheme.bodyLarge,
              ),
            ),
            body: Center(
              child: Padding(
                padding: const EdgeInsets.all(8),
                child: Column(
                  children: [
                    Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        IconButton(
                          icon: const Icon(Icons.remove_rounded),
                          onPressed: () async {
                            final newVolume =
                                await VolumeController().getVolume();
                            VolumeController().setVolume(
                              _getVolume - 0.1,
                              showSystemUI: false,
                            );
                            setState(() {
                              _getVolume = newVolume;
                            });
                          },
                        ),
                        Icon(
                          _getVolume > 0.5
                              ? Icons.volume_up_rounded
                              : Icons.volume_down_rounded,
                        ),
                        IconButton(
                          icon: const Icon(Icons.add_rounded),
                          onPressed: () async {
                            final newVolume =
                                await VolumeController().getVolume();
                            VolumeController().setVolume(
                              newVolume + 0.1,
                              showSystemUI: false,
                            );
                            setState(() {
                              _getVolume = newVolume;
                            });
                          },
                        ),
                      ],
                    ),
                    Text(
                      l10n.localListening,
                      style: theme.textTheme.labelMedium,
                    ),
                    _buildOfflineMediaAction(theme),
                  ],
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildOfflineMediaAction(ThemeData theme) {
    if (localMediaFilePath != '' && !isBuffering) {
      return Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Padding(
            padding: const EdgeInsets.all(12),
            child: Icon(
              Icons.download_done_rounded,
              color: theme.colorScheme.primary,
            ),
          ),
          IconButton(
            icon: const Icon(
              Icons.delete_forever_rounded,
              color: Colors.red,
            ),
            onPressed: () async {
              unawaited(widget.playerController.player.stop());
              await widget.playerController.syncOpenSession();
              if (mounted) {
                setState(() {
                  localMediaFilePath = '';
                });
              }
              await widget.playerController.deleteMedia();
              await widget.playerController.checkAndSetAudioSource();
              unawaited(widget.playerController.player.play());
            },
          ),
        ],
      );
    } else {
      if (isDownloading) {
        return SizedBox(
          height: 48,
          width: 48,
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: CircularProgressIndicator(
              strokeWidth: 2.5,
              color: theme.colorScheme.secondary,
            ),
          ),
        );
      } else {
        return IconButton(
          icon: Icon(
            Icons.download_rounded,
            color: theme.colorScheme.secondary,
          ),
          onPressed: () async {
            if (localMediaFilePath == '' && !isBuffering) {
              if (kDebugMode) {
                print('Downloading media');
              }
              if (mounted) {
                setState(() {
                  isDownloading = true;
                });
              }
              await widget.playerController.downloadFile();
              await widget.playerController.checkAndSetAudioSource();
              final newLocalMediaFilePath =
                  await widget.playerController.getLocalFilePath(
                getAudioFile: true,
              );
              unawaited(widget.playerController.player.play());
              if (mounted) {
                setState(() {
                  localMediaFilePath = newLocalMediaFilePath;
                  isDownloading = false;
                });
              }
            }
          },
        );
      }
    }
  }
}
