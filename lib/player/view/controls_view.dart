import 'dart:async';

import 'package:abs_wear/l10n/l10n.dart';
import 'package:abs_wear/player/darts/audio_player.dart';
import 'package:flutter/material.dart';
import 'package:fluttertoast/fluttertoast.dart';
import 'package:volume_controller/volume_controller.dart';

enum _LocalState { none, partial, complete }

class ControlViewPage extends StatefulWidget {
  const ControlViewPage({required this.playerController, super.key});
  final AudioPlayerController playerController;

  @override
  State<ControlViewPage> createState() => _ControlViewPageState();
}

class _ControlViewPageState extends State<ControlViewPage> {
  final VolumeController _volume = VolumeController.instance;
  double _currentVolume = 0;
  _LocalState _local = _LocalState.none;
  StreamSubscription<double>? _volumeSubscription;

  AudioPlayerController get _controller => widget.playerController;

  @override
  void initState() {
    super.initState();
    _volume.showSystemUI = false;
    _volumeSubscription = _volume.addListener((v) {
      if (mounted) setState(() => _currentVolume = v);
    });
    _controller.addListener(_refreshLocal);
    unawaited(_refreshLocal());
  }

  @override
  void dispose() {
    unawaited(_volumeSubscription?.cancel());
    _controller.removeListener(_refreshLocal);
    super.dispose();
  }

  Future<void> _refreshLocal() async {
    final local = await _controller.isDownloaded()
        ? _LocalState.complete
        : await _controller.hasLocalFiles()
        ? _LocalState.partial
        : _LocalState.none;
    if (mounted && local != _local) setState(() => _local = local);
  }

  Future<void> _changeVolume(double delta) async {
    final current = await _volume.getVolume();
    final next = (current + delta).clamp(0.0, 1.0);
    await _volume.setVolume(next);
    if (mounted) setState(() => _currentVolume = next);
  }

  Future<void> _toast(String msg) =>
      Fluttertoast.showToast(msg: msg, gravity: ToastGravity.CENTER);

  Future<void> _download() async {
    final l10n = context.l10n;
    final result = await _controller.downloadBook();
    // Leaving the player cancels the download; no toast on another page.
    if (!mounted) return;
    unawaited(
      _toast(switch (result) {
        DownloadResult.done => l10n.downloadDone,
        DownloadResult.noSpace => l10n.downloadNoSpace,
        DownloadResult.failed => l10n.downloadFailed,
      }),
    );
  }

  Future<void> _confirmDelete() async {
    final l10n = context.l10n;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        insetPadding: const EdgeInsets.symmetric(horizontal: 12),
        contentPadding: const EdgeInsets.fromLTRB(20, 24, 20, 0),
        actionsPadding: const EdgeInsets.only(bottom: 12),
        content: Text(
          l10n.deleteDownloadConfirm,
          textAlign: TextAlign.center,
          style: Theme.of(context).textTheme.bodySmall,
        ),
        actionsAlignment: MainAxisAlignment.center,
        actions: [
          IconButton(
            tooltip: l10n.cancel,
            icon: const Icon(Icons.close_rounded),
            onPressed: () => Navigator.pop(context, false),
          ),
          IconButton(
            tooltip: l10n.deleteDownload,
            icon: const Icon(Icons.check_rounded),
            onPressed: () => Navigator.pop(context, true),
          ),
        ],
      ),
    );
    if (confirmed ?? false) await _controller.deleteDownload();
  }

  /// 1.0 -> "1", 1.25 -> "1.25", 1.5 -> "1.5".
  static String _formatSpeed(double speed) {
    final text = speed.toStringAsFixed(2);
    return text.replaceFirst(RegExp(r'\.?0+$'), '');
  }

  static String _formatLeft(Duration left) {
    String two(int n) => n.toString().padLeft(2, '0');
    return '${two(left.inMinutes)}:${two(left.inSeconds % 60)}';
  }

  IconData get _volumeIcon {
    if (_currentVolume <= 0) return Icons.volume_off_rounded;
    if (_currentVolume < 0.5) return Icons.volume_down_rounded;
    return Icons.volume_up_rounded;
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(
        toolbarHeight: 40,
        centerTitle: true,
        automaticallyImplyLeading: false,
        title: Text(l10n.controls, style: theme.textTheme.bodyLarge),
      ),
      // Scrolls rather than overflowing on small screens or large text.
      // Not primary: the page's round scrollbar makes the player's
      // PageController the primary one, which this must not attach to.
      body: SingleChildScrollView(
        primary: false,
        child: Padding(
          padding: const EdgeInsets.all(8),
          child: Column(
            children: [
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  IconButton(
                    tooltip: l10n.volumeDown,
                    icon: const Icon(Icons.remove_rounded),
                    onPressed: () => unawaited(_changeVolume(-0.1)),
                  ),
                  Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(_volumeIcon, size: 20),
                      Text(
                        '${(_currentVolume * 100).round()}%',
                        style: theme.textTheme.labelSmall,
                      ),
                    ],
                  ),
                  IconButton(
                    tooltip: l10n.volumeUp,
                    icon: const Icon(Icons.add_rounded),
                    onPressed: () => unawaited(_changeVolume(0.1)),
                  ),
                ],
              ),
              Text(l10n.speed, style: theme.textTheme.labelMedium),
              ListenableBuilder(
                listenable: _controller,
                builder: (context, _) => Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    IconButton(
                      tooltip: l10n.slower,
                      icon: const Icon(Icons.remove_rounded),
                      onPressed: _controller.isLoaded
                          ? () => unawaited(_controller.changeSpeed(-1))
                          : null,
                    ),
                    SizedBox(
                      width: 48,
                      child: Text(
                        '${_formatSpeed(_controller.speed)}x',
                        textAlign: TextAlign.center,
                        style: theme.textTheme.labelLarge,
                      ),
                    ),
                    IconButton(
                      tooltip: l10n.faster,
                      icon: const Icon(Icons.add_rounded),
                      onPressed: _controller.isLoaded
                          ? () => unawaited(_controller.changeSpeed(1))
                          : null,
                    ),
                  ],
                ),
              ),
              ValueListenableBuilder<Duration?>(
                valueListenable: _controller.sleepRemaining,
                builder: (context, left, _) => TextButton.icon(
                  onPressed: _controller.cycleSleepTimer,
                  icon: Icon(
                    left == null
                        ? Icons.bedtime_off_rounded
                        : Icons.bedtime_rounded,
                    semanticLabel: l10n.sleepTimer,
                  ),
                  label: Text(
                    left == null ? l10n.sleepTimerOff : _formatLeft(left),
                    style: theme.textTheme.labelLarge,
                  ),
                ),
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
    final l10n = context.l10n;
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
    final download = IconButton(
      tooltip: l10n.download,
      icon: Icon(Icons.download_rounded, color: theme.colorScheme.secondary),
      onPressed: _controller.isLoaded ? () => unawaited(_download()) : null,
    );
    // Until the session is loaded the track list is unknown, so the local
    // state can't be judged (and nothing should be deleted mid-setup).
    if (!_controller.isLoaded) return download;
    final delete = IconButton(
      tooltip: l10n.deleteDownload,
      icon: Icon(Icons.delete_forever_rounded, color: theme.colorScheme.error),
      onPressed: () => unawaited(_confirmDelete()),
    );
    if (_local == _LocalState.complete) {
      return Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Padding(
            padding: const EdgeInsets.all(12),
            child: Icon(
              Icons.download_done_rounded,
              semanticLabel: l10n.downloadDone,
              color: theme.colorScheme.primary,
            ),
          ),
          delete,
        ],
      );
    }
    // Leftovers of a failed download: resume, or free the space.
    if (_local == _LocalState.partial) {
      return Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [download, delete],
      );
    }
    return download;
  }
}
