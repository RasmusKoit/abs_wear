import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Channel MainActivity sends crown (rotary input) turns on: `true` for a
/// clockwise detent, `false` for counter-clockwise.
@visibleForTesting
const crownChannel = EventChannel('crown');

/// Crown turns, `true` when clockwise. Shared by all listeners.
final Stream<bool> crownTurns = crownChannel.receiveBroadcastStream().map(
  (event) => event as bool,
);
