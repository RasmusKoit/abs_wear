import 'package:abs_wear/l10n/l10n.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('AppLocalizations', () {
    test('English is the first (fallback) locale', () {
      expect(AppLocalizations.supportedLocales.first, const Locale('en'));
    });

    for (final locale in AppLocalizations.supportedLocales) {
      test('$locale formats every parameterised message', () {
        final l10n = lookupAppLocalizations(locale);
        expect(l10n.hello('Bob'), contains('Bob'));
        expect(l10n.serverError(502), contains('502'));
        expect(l10n.timeLeftLabel('00:12:34'), contains('00:12:34'));
        for (final n in [0, 1, 2, 3, 5, 11, 21, 100, 653]) {
          expect(l10n.bookCount(n), isNotEmpty);
          expect(l10n.podcastCount(n), isNotEmpty);
        }
        expect(l10n.bookCount(653), contains('653'));
        for (final n in [0, 1, 2, 3, 5, 11, 21, 59]) {
          expect(l10n.hoursCount(n), isNotEmpty);
          expect(l10n.minutesCount(n), isNotEmpty);
          expect(l10n.secondsCount(n), isNotEmpty);
        }
        expect(l10n.minutesCount(42), contains('42'));
        expect(l10n.volumeLevel(70), contains('70'));
        expect(l10n.loading, isNotEmpty);
        expect(l10n.podcastCount(12), contains('12'));
      });

      test('$locale reads durations with numbers', () {
        final l10n = lookupAppLocalizations(locale);
        final spoken = l10n.spokenDuration(
          const Duration(hours: 3, minutes: 5, seconds: 9),
        );
        expect(spoken, allOf(contains('3'), contains('5')));
        expect(spoken, isNot(contains('9')), reason: 'no seconds past 1 h');
        expect(spoken, isNot(contains(':')));
      });

      test('$locale is supported by the Material and Widgets delegates', () {
        expect(GlobalMaterialLocalizations.delegate.isSupported(locale), true);
        expect(GlobalWidgetsLocalizations.delegate.isSupported(locale), true);
      });
    }

    testWidgets('unsupported device locale falls back to English', (
      tester,
    ) async {
      late AppLocalizations l10n;
      await tester.pumpWidget(
        MaterialApp(
          locale: const Locale('sv'),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: Builder(
            builder: (context) {
              l10n = context.l10n;
              return const SizedBox();
            },
          ),
        ),
      );
      expect(l10n.localeName, 'en');
    });

    for (final code in ['ar', 'ur']) {
      testWidgets('$code lays out right-to-left', (tester) async {
        late TextDirection direction;
        await tester.pumpWidget(
          MaterialApp(
            locale: Locale(code),
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            home: Builder(
              builder: (context) {
                direction = Directionality.of(context);
                return Text(context.l10n.continueListening);
              },
            ),
          ),
        );
        expect(direction, TextDirection.rtl);
        expect(tester.takeException(), isNull);
      });
    }
  });

  group('spokenDuration', () {
    final l10n = lookupAppLocalizations(const Locale('en'));

    for (final (duration, seconds, spoken) in [
      (
        const Duration(hours: 1, minutes: 6, seconds: 40),
        true,
        '1 hour 6 minutes',
      ),
      (const Duration(hours: 2), true, '2 hours'),
      (const Duration(minutes: 6, seconds: 40), true, '6 minutes 40 seconds'),
      (const Duration(minutes: 1), true, '1 minute'),
      (const Duration(seconds: 1), true, '1 second'),
      (Duration.zero, true, '0 minutes'),
      (const Duration(minutes: 6, seconds: 40), false, '6 minutes'),
      (const Duration(seconds: 40), false, '0 minutes'),
    ]) {
      test('$duration${seconds ? '' : ' in minutes'} is "$spoken"', () {
        expect(l10n.spokenDuration(duration, seconds: seconds), spoken);
      });
    }
  });
}
