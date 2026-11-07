import 'dart:async';

import 'package:abs_wear/l10n/l10n.dart';
import 'package:abs_wear/player/darts/audio_player.dart';
import 'package:flutter/material.dart';
import 'package:fluttertoast/fluttertoast.dart';
import 'package:volume_controller/volume_controller.dart';

class ControlViewPage extends StatefulWidget {
  const ControlViewPage({required this.playerController, super.key});
  final AudioPlayerController playerController;

  @override
  State<ControlViewPage> createState() => _ControlViewPageState();
}

class _ControlViewPageState extends State<ControlViewPage> {
  final VolumeController _volume = VolumeController.instance;
  double _currentVolume = 0;
  bool _downloaded = false;
  StreamSubscription<double>? _volumeSubscription;

  AudioPlayerController get _controller => widget.playerController;

  @override
  void initState() {
    super.initState();
    _volume.showSystemUI = false;
    _volumeSubscription = _volume.addListener((v) {
      if (mounted) setState(() => _currentVolume = v);
    });
    _controller.addListener(_refreshDownloaded);
    unawaited(_refreshDownloaded());
  }

  @override
  void dispose() {
    unawaited(_volumeSubscription?.cancel());
    _controller.removeListener(_refreshDownloaded);
    super.dispose();
  }

  Future<void> _refreshDownloaded() async {
    final downloaded = await _controller.isDownloaded();
    if (mounted && downloaded != _downloaded) {
      setState(() => _downloaded = downloaded);
    }
  }

  Future<void> _changeVolume(double delta) async {
    final current = await _volume.getVolume();
    final next = (current + delta).clamp(0.0, 1.0);
    await _volume.setVolume(next);
    if (mounted) setState(() => _currentVolume = next);
  }

  Future<void> _download() async {
    final ok = await _controller.downloadBook();
    unawaited(
      Fluttertoast.showToast(
        msg: ok ? 'Audiobook downloaded!' : 'Failed to download the file!',
        gravity: ToastGravity.CENTER,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(
        centerTitle: true,
        automaticallyImplyLeading: false,
        title: Text(l10n.controls, style: theme.textTheme.bodyLarge),
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
                    onPressed: () => unawaited(_changeVolume(-0.1)),
                  ),
                  Icon(
                    _currentVolume > 0.5
                        ? Icons.volume_up_rounded
                        : Icons.volume_down_rounded,
                  ),
                  IconButton(
                    icon: const Icon(Icons.add_rounded),
                    onPressed: () => unawaited(_changeVolume(0.1)),
                  ),
                ],
              ),
              Text(l10n.localListening, style: theme.textTheme.labelMedium),
              ListenableBuilder(
                listenable: _controller,
                builder: (context, _) => _buildOfflineMediaAction(theme),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildOfflineMediaAction(ThemeData theme) {
    if (_controller.isDownloading) {
      return ValueListenableBuilder<double?>(
        valueListenable: _controller.downloadProgress,
        builder: (context, progress, _) => Column(
          children: [
            SizedBox.square(
              dimension: 48,
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: CircularProgressIndicator(
                  value: progress,
                  strokeWidth: 2.5,
                  color: theme.colorScheme.secondary,
                ),
              ),
            ),
            Text(
              '${((progress ?? 0) * 100).floor()}%',
              style: theme.textTheme.labelSmall,
            ),
          ],
        ),
      );
    }
    if (_downloaded) {
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
            icon: const Icon(Icons.delete_forever_rounded, color: Colors.red),
            onPressed: () => unawaited(_controller.deleteDownload()),
          ),
        ],
      );
    }
    return IconButton(
      icon: Icon(Icons.download_rounded, color: theme.colorScheme.secondary),
      onPressed: _controller.isLoaded ? () => unawaited(_download()) : null,
    );
  }
}
