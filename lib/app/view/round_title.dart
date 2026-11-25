import 'package:flutter/material.dart';

/// A page's fixed title, shrunk to fit the round screen's top.
class RoundTitle extends StatelessWidget {
  const RoundTitle(this.text, {super.key});

  final String text;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(horizontal: 40),
    child: FittedBox(
      fit: BoxFit.scaleDown,
      child: Text(text, style: Theme.of(context).textTheme.bodyLarge),
    ),
  );
}
