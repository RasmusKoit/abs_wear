import 'package:abs_wear/l10n/l10n.dart';
import 'package:abs_wear/player/darts/audio_player.dart';
import 'package:flutter/material.dart';

/// The time left in the chapter as "01:06:40" (or "01:06" without
/// [seconds]), read out by screen readers in words.
class TimeLeftWidget extends StatelessWidget {
  const TimeLeftWidget({
    required this.timeLeft,
    required this.style,
    this.seconds = true,
    super.key,
  });
  final Duration timeLeft;
  final TextStyle style;

  /// Whether to show seconds; the always-on display shows minutes only.
  final bool seconds;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final text = formatDuration(timeLeft);
    return Text(
      seconds ? text : text.substring(0, text.length - 3),
      style: style,
      semanticsLabel: l10n.timeLeftLabel(
        l10n.spokenDuration(timeLeft, seconds: seconds),
      ),
    );
  }
}
