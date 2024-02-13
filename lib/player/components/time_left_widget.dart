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
    );
  }
}
