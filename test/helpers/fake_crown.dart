import 'package:abs_wear/app/crown.dart';
import 'package:flutter_test/flutter_test.dart';

/// Answers the crown channel (a silent crown), for pages with a
/// CrownScrollbar whose listen would otherwise fail outside a device.
void fakeCrown() {
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        ..setMockStreamHandler(
          crownChannel,
          MockStreamHandler.inline(onListen: (_, _) {}),
        );
  addTearDown(() => messenger.setMockStreamHandler(crownChannel, null));
}
