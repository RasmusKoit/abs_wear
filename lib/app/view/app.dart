import 'package:abs_wear/ambient_mode/ambient_mode.dart';
import 'package:abs_wear/l10n/l10n.dart';
import 'package:abs_wear/login/login.dart';
import 'package:flutter/material.dart';

/// The app's theme; [ambient] is the dimmed always-on variant.
ThemeData appTheme({bool ambient = false}) => ThemeData(
  useMaterial3: true,
  // Standard density: compact shrank every tap target to 40 dp,
  // too small to hit reliably on a watch.
  visualDensity: VisualDensity.standard,
  // Ambient (always-on) mode: black background and dimmed, colorless
  // content, so few pixels are lit (battery and burn-in).
  colorScheme: ambient
      ? const ColorScheme.dark(
          primary: Colors.white60,
          secondary: Colors.white54,
          error: Colors.white54,
          surface: Colors.black,
          onSurface: Colors.white60,
        )
      // The logo's colours, kept dark: a true black background (unlit on
      // OLED), cream text, its sage for small accents.
      : const ColorScheme.dark(
          primary: LogoColors.sage,
          onPrimary: LogoColors.navy,
          secondary: LogoColors.sage,
          onSecondary: LogoColors.navy,
          surface: Colors.black,
          onSurface: LogoColors.cream,
          // Destructive buttons (Logout): a dark red with cream text.
          errorContainer: LogoColors.danger,
          onErrorContainer: LogoColors.cream,
        ),
  // The one main action on a screen: filled, so it reads as a button on
  // the black background (text buttons are the secondary actions).
  elevatedButtonTheme: ElevatedButtonThemeData(
    style: ElevatedButton.styleFrom(
      backgroundColor: ambient ? Colors.white24 : LogoColors.slate,
      foregroundColor: ambient ? Colors.white60 : LogoColors.cream,
      textStyle: const TextStyle(fontSize: 14, fontWeight: FontWeight.w500),
    ),
  ),
);

/// The colours of the app's logo.
abstract final class LogoColors {
  static const cream = Color(0xFFF7F1D9);
  static const navy = Color(0xFF032436);
  static const slate = Color(0xFF4B6772);
  static const sage = Color(0xFF7D9E94);

  /// Not in the logo: a dark red for destructive buttons, muted to sit
  /// with the slate and navy.
  static const danger = Color(0xFF7A2C2C);
}

/// The largest text scale the layouts are made for; larger system font
/// sizes are clamped to it.
const double maxTextScale = 1.3;

/// [context]'s media query with the text scale clamped to what the round
/// layouts fit.
MediaQueryData clampedMediaQuery(BuildContext context) {
  final data = MediaQuery.of(context);
  return data.copyWith(
    textScaler: data.textScaler.clamp(
      minScaleFactor: 0.8,
      maxScaleFactor: maxTextScale,
    ),
  );
}

class App extends StatelessWidget {
  const App({super.key});

  @override
  Widget build(BuildContext context) {
    return AmbientModeBuilder(
      child: const LoginPage(),
      builder: (context, isAmbientModeActive, child) {
        return MaterialApp(
          theme: appTheme(ambient: isAmbientModeActive),
          debugShowCheckedModeBanner: false,
          // Switch to and from the ambient theme instantly: a theme lerp
          // would draw frames just as the display goes low-power.
          themeAnimationStyle: AnimationStyle.noAnimation,
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: child,
          builder: (context, child) => MediaQuery(
            data: clampedMediaQuery(context),
            // No animations (spinners, transitions) while ambient.
            child: TickerMode(enabled: !isAmbientModeActive, child: child!),
          ),
        );
      },
    );
  }
}
