import 'package:abs_wear/ambient_mode/ambient_mode.dart';
import 'package:abs_wear/l10n/l10n.dart';
import 'package:abs_wear/login/login.dart';
import 'package:flutter/material.dart';

class App extends StatelessWidget {
  const App({super.key});

  @override
  Widget build(BuildContext context) {
    return AmbientModeBuilder(
      child: const LoginPage(),
      builder: (context, isAmbientModeActive, child) {
        return MaterialApp(
          theme: ThemeData(
            useMaterial3: true,
            // This makes elements such as buttons have a fewer pixels in
            // padding and general spacing. good for devices with limited screen
            // real state.
            visualDensity: VisualDensity.compact,
            // When in ambient mode, change the apps color scheme
            // Ambient (always-on) mode: black background and dimmed, colorless
            // content, so few pixels are lit (battery and burn-in).
            colorScheme: isAmbientModeActive
                ? const ColorScheme.dark(
                    primary: Colors.white60,
                    secondary: Colors.white54,
                    error: Colors.white54,
                    surface: Colors.black,
                    onSurface: Colors.white60,
                  )
                : const ColorScheme.dark(primary: Color(0xFF00B5FF)),
          ),
          debugShowCheckedModeBanner: false,
          // Switch to and from the ambient theme instantly: a theme lerp
          // would draw frames just as the display goes low-power.
          themeAnimationStyle: AnimationStyle.noAnimation,
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: child,
          builder: (context, child) {
            final mediaQueryData = MediaQuery.of(context);
            final textScaler = mediaQueryData.textScaler.clamp(
              minScaleFactor: 0.8,
              maxScaleFactor: 1.3,
            );
            return MediaQuery(
              data: MediaQuery.of(context).copyWith(textScaler: textScaler),
              // No animations (spinners, transitions) while ambient.
              child: TickerMode(enabled: !isAmbientModeActive, child: child!),
            );
          },
        );
      },
    );
  }
}
