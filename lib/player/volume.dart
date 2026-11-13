import 'package:flutter/material.dart';
import 'package:volume_controller/volume_controller.dart';

/// Moves media volume by [delta] from [from] (or now), clamped; returns it.
Future<double> changeVolume(double delta, {double? from}) async {
  final volume = VolumeController.instance..showSystemUI = false;
  final current = from ?? await volume.getVolume();
  final next = (current + delta).clamp(0.0, 1.0);
  await volume.setVolume(next);
  return next;
}

/// Speaker icon for a volume [level] from 0 to 1.
IconData volumeIcon(double level) {
  if (level <= 0) return Icons.volume_off_rounded;
  if (level < 0.5) return Icons.volume_down_rounded;
  return Icons.volume_up_rounded;
}
