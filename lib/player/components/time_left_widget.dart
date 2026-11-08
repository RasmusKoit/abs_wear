import 'package:abs_wear/l10n/l10n.dart';
import 'package:flutter/material.dart';

class TimeLeftWidget extends StatelessWidget {
  const TimeLeftWidget({
    required this.timeLeft,
    required this.style,
    super.key,
  });
  final String timeLeft;
  final TextStyle style;

  @override
  Widget build(BuildContext context) {
    return Text(
      timeLeft,
      style: style,
      semanticsLabel: context.l10n.timeLeftLabel(timeLeft),
    );
  }
}
