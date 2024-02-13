import 'package:flutter/material.dart';
import 'package:text_scroll/text_scroll.dart';

class ScrollingText extends StatefulWidget {
  const ScrollingText({
    required this.text,
    required this.style,
    super.key,
  });
  final String text;
  final TextStyle style;

  @override
  State<ScrollingText> createState() => _ScrollingTextState();
}

class _ScrollingTextState extends State<ScrollingText> {
  @override
  Widget build(BuildContext context) {
    return TextScroll(
      widget.text,
      velocity: const Velocity(pixelsPerSecond: Offset(25, 0)),
      pauseBetween: const Duration(seconds: 1),
      style: widget.style,
    );
  }
}
