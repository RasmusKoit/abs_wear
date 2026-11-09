import 'package:abs_wear/app/view/app.dart';
import 'package:abs_wear/l10n/l10n.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// The text scales every main screen must fit: the system default, the
/// largest the app allows ([maxTextScale]), and some headroom past it.
const watchTextScales = <double>[1, maxTextScale, 1.5];

/// Makes the test surface a round watch's: 454x454 px at 2 dpr (227 dp
/// across), about the emulator's size and a little smaller than a OnePlus
/// Watch 2 (466 px).
void useWatchScreen(WidgetTester tester) {
  tester.view
    ..physicalSize = const Size.square(454)
    ..devicePixelRatio = 2;
  addTearDown(tester.view.reset);
}

/// [home] in the app's own theme and localizations, at [textScale] and
/// with or without the system's bold text setting. Unlike the app, the
/// scale is not clamped, so tests can go past [maxTextScale].
Widget watchApp(
  Widget home, {
  double textScale = 1,
  bool boldText = false,
  bool ambient = false,
  Locale? locale,
}) => MaterialApp(
  theme: appTheme(ambient: ambient),
  locale: locale,
  localizationsDelegates: AppLocalizations.localizationsDelegates,
  supportedLocales: AppLocalizations.supportedLocales,
  home: home,
  builder: (context, child) => MediaQuery(
    data: MediaQuery.of(
      context,
    ).copyWith(textScaler: TextScaler.linear(textScale), boldText: boldText),
    child: child!,
  ),
);

/// Checks the current screen against Android's accessibility guidelines:
/// tap targets of at least 48x48 dp, a label on everything tappable and,
/// with [contrast], readable text contrast.
Future<void> expectAccessible(
  WidgetTester tester, {
  bool contrast = true,
}) async {
  final semantics = tester.ensureSemantics();
  await expectLater(tester, meetsGuideline(androidTapTargetGuideline));
  await expectLater(tester, meetsGuideline(labeledTapTargetGuideline));
  if (contrast) {
    await expectLater(tester, meetsGuideline(textContrastGuideline));
  }
  semantics.dispose();
}

/// Fails if a RenderFlex overflowed or anything else threw while laying
/// out the screen (overflow errors are reported, not thrown, so a test
/// would otherwise only see them at its end).
void expectNoLayoutErrors(WidgetTester tester) {
  expect(tester.takeException(), isNull);
}

/// Whether [finder]'s widget lies fully on the round screen: inside the
/// circle inscribed in the test surface.
bool onRoundScreen(WidgetTester tester, Finder finder) {
  final size = tester.view.physicalSize / tester.view.devicePixelRatio;
  final center = size.center(Offset.zero);
  final radius = size.shortestSide / 2;
  final rect = tester.getRect(finder);
  return [
    rect.topLeft,
    rect.topRight,
    rect.bottomLeft,
    rect.bottomRight,
  ].every((corner) => (corner - center).distance <= radius + 0.5);
}
