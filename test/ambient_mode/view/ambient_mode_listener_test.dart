import 'package:audiobookshelfwear/ambient_mode/ambient_mode.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../helpers/helpers.dart';

void main() {
  group('$AmbientModeListener', () {
    test('updates when ambient mode is activated', () {
      final listener = AmbientModeListener.instance..value = false;

      simulatePlatformCall('ambient_mode', 'onEnterAmbient');

      expect(listener.isAmbientModeActive, isTrue);
    });

    test('updates when ambient mode is update', () {
      final listener = AmbientModeListener.instance..value = false;

      simulatePlatformCall('ambient_mode', 'onUpdateAmbient');

      expect(listener.isAmbientModeActive, isTrue);
    });

    test('updates when ambient mode is deactivated', () async {
      final listener = AmbientModeListener.instance..value = true;

      await simulatePlatformCall('ambient_mode', 'onExitAmbient');

      expect(listener.isAmbientModeActive, isFalse);
    });

    test('doesnt change on unkown method', () async {
      final listener = AmbientModeListener.instance..value = true;

      await simulatePlatformCall('ambient_mode', 'onUnknownMethod');

      expect(listener.isAmbientModeActive, isTrue);
    });
  });
}
