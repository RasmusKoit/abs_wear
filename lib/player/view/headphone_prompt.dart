import 'dart:async';

import 'package:abs_wear/l10n/l10n.dart';
import 'package:abs_wear/player/darts/audio_output.dart';
import 'package:abs_wear/player/darts/audio_player.dart';
import 'package:flutter/material.dart';

// Speaker picked: no prompt until headphones are seen or the app restarts.
bool _speakerChosen = false;

/// Forgets the speaker choice, as an app restart does.
@visibleForTesting
void resetHeadphonePrompt() => _speakerChosen = false;

/// True to play: headphones on, speaker chosen, or connected while asking.
Future<bool> confirmAudioOutput(BuildContext context) async {
  if (await AudioOutput.hasHeadphones()) {
    _speakerChosen = false;
    return true;
  }
  if (_speakerChosen) return true;
  if (!context.mounted) return false;
  final play = await showDialog<bool>(
    context: context,
    builder: (context) => const _HeadphonePrompt(),
  );
  return play ?? false;
}

/// Play/pause for on-screen buttons; media buttons skip the headphone check.
Future<void> togglePlayChecked(
  BuildContext context,
  AudioPlayerController controller,
) async {
  if (controller.toggleWouldPlay &&
      (!await confirmAudioOutput(context) || !controller.toggleWouldPlay)) {
    return;
  }
  await controller.togglePlayPause();
}

class _HeadphonePrompt extends StatefulWidget {
  const _HeadphonePrompt();

  @override
  State<_HeadphonePrompt> createState() => _HeadphonePromptState();
}

class _HeadphonePromptState extends State<_HeadphonePrompt> {
  StreamSubscription<bool>? _changes;

  @override
  void initState() {
    super.initState();
    _changes = AudioOutput.changes.listen((connected) {
      if (connected) _close();
    });
  }

  // Pops once: a later pop would close the page under the closing dialog.
  void _close({bool speaker = false}) {
    if (_changes == null || !mounted) return;
    if (!(ModalRoute.of(context)?.isCurrent ?? false)) return;
    unawaited(_changes!.cancel());
    _changes = null;
    if (speaker) _speakerChosen = true;
    Navigator.pop(context, true);
  }

  @override
  void dispose() {
    unawaited(_changes?.cancel());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    return AlertDialog(
      insetPadding: const EdgeInsets.symmetric(horizontal: 12),
      contentPadding: const EdgeInsets.fromLTRB(20, 24, 20, 0),
      actionsPadding: const EdgeInsets.only(bottom: 12),
      content: Text(
        l10n.noHeadphones,
        textAlign: TextAlign.center,
        style: Theme.of(context).textTheme.bodySmall,
      ),
      actionsAlignment: MainAxisAlignment.center,
      actions: [
        IconButton(
          tooltip: l10n.connectHeadphones,
          icon: const Icon(Icons.bluetooth_rounded),
          onPressed: () => unawaited(AudioOutput.openBluetoothSettings()),
        ),
        IconButton(
          tooltip: l10n.playOnSpeaker,
          icon: const Icon(Icons.volume_up_rounded),
          onPressed: () => _close(speaker: true),
        ),
      ],
    );
  }
}
