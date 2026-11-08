import 'package:abs_wear/ambient_mode/ambient_mode.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../helpers/helpers.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('$AmbientModeListener', () {
    test('updates when ambient mode is activated', () async {
      final listener = AmbientModeListener.instance..value = false;

      await simulatePlatformCall('ambient_mode', 'onEnterAmbient');

      expect(listener.isAmbientModeActive, isTrue);
    });

    test('updates when ambient mode is update', () async {
      final listener = AmbientModeListener.instance..value = false;

      await simulatePlatformCall('ambient_mode', 'onUpdateAmbient');

      expect(listener.isAmbientModeActive, isTrue);
    });

    test('counts ambient updates so dimmed UI can redraw', () async {
      final listener = AmbientModeListener.instance;
      final before = listener.updates.value;

      await simulatePlatformCall('ambient_mode', 'onUpdateAmbient');

      expect(listener.updates.value, before + 1);
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
