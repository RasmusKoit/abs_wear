import 'package:abs_wear/l10n/l10n.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  // An exact `=1{...}` case becomes intl's `one:`, and in some languages
  // (pt, hi, fr ...) `one` also covers 0: without an `=0{...}` case, zero
  // would read "1 livro".
  for (final locale in AppLocalizations.supportedLocales) {
    test('${locale.languageCode}: 0, 1 and 2 read differently', () {
      final l10n = lookupAppLocalizations(locale);
      final counts = <String, String Function(int)>{
        'bookCount': l10n.bookCount,
        'podcastCount': l10n.podcastCount,
        'hoursCount': l10n.hoursCount,
        'minutesCount': l10n.minutesCount,
        'secondsCount': l10n.secondsCount,
      };
      for (final MapEntry(key: name, value: count) in counts.entries) {
        final one = count(1);
        expect(count(0), isNot(one), reason: '$name(0)');
        expect(count(2), isNot(one), reason: '$name(2)');
        // A count shown as a number is the right number.
        for (final n in [0, 2, 5]) {
          final text = count(n);
          if (RegExp(r'\d').hasMatch(text)) {
            expect(text, contains('$n'), reason: '$name($n): $text');
          }
        }
      }
    });
  }
}
