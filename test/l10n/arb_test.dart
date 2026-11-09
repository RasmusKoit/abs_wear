import 'dart:convert';
import 'dart:io';

import 'package:abs_wear/l10n/l10n.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

/// Guards the ARB files themselves: every locale has every message, with
/// the template's placeholders and well-formed plurals, and nothing is left
/// in English by accident.
void main() {
  const dir = 'lib/l10n/arb';
  Map<String, dynamic> read(String path) =>
      jsonDecode(File(path).readAsStringSync()) as Map<String, dynamic>;

  final template = read('$dir/app_en.arb');
  final keys = template.keys.where((k) => !k.startsWith('@')).toList();
  final locales = {
    for (final file in Directory(dir).listSync().whereType<File>())
      if (RegExp(r'app_(\w+)\.arb$').firstMatch(file.path) case final m?)
        if (m[1] != 'en') m[1]!: read(file.path),
  };

  // Identical to the English on purpose: the same word, or a loanword the
  // language uses as is. Anything else identical is an untranslated string.
  const sameAsEnglish = {
    'de': {'pause', 'downloads'},
    'es': {'podcastCount'},
    'fr': {'pause'},
    'it': {'passwordLabel', 'sleepTimerOff'},
    'pt': {'downloads'},
  };

  test('every ARB locale is supported, and every supported locale has one', () {
    expect(
      {...locales.keys, 'en'},
      {for (final l in AppLocalizations.supportedLocales) l.languageCode},
    );
  });

  group('template', () {
    for (final key in keys) {
      test('$key has a description and declares its placeholders', () {
        final meta = template['@$key'] as Map<String, dynamic>?;
        expect(meta, isNotNull, reason: '@$key is missing');
        expect(meta!['description'], isA<String>());
        final declared =
            (meta['placeholders'] as Map<String, dynamic>? ?? const {}).keys;
        expect(declared.toSet(), icuArguments(template[key] as String));
      });
    }

    test('has no metadata without a message', () {
      for (final key in template.keys) {
        if (key.startsWith('@') && key != '@@locale') {
          expect(template.containsKey(key.substring(1)), true, reason: key);
        }
      }
    });
  });

  for (final MapEntry(key: locale, value: arb) in locales.entries) {
    group(locale, () {
      test('names its locale and carries no metadata', () {
        expect(arb['@@locale'], locale);
        expect(
          arb.keys.where((k) => k.startsWith('@') && k != '@@locale'),
          isEmpty,
        );
      });

      test('has exactly the template keys', () {
        final own = arb.keys.where((k) => !k.startsWith('@')).toSet();
        expect(keys.toSet().difference(own), isEmpty, reason: 'missing');
        expect(own.difference(keys.toSet()), isEmpty, reason: 'unknown');
      });

      test('keeps the template placeholders, with valid plurals', () {
        for (final key in keys) {
          final message = arb[key];
          if (message is! String) continue;
          expect(
            icuArguments(message),
            icuArguments(template[key] as String),
            reason: '$locale $key: $message',
          );
        }
      });

      test('has nothing left in English', () {
        final allowed = sameAsEnglish[locale] ?? const <String>{};
        final same = [
          for (final key in keys)
            if (arb[key] == template[key] && !allowed.contains(key)) key,
        ];
        expect(same, isEmpty);
      });

      test('generates every message', () {
        final l10n = lookupAppLocalizations(Locale(locale));
        expect(l10n.playbackError, isNotEmpty);
        expect(l10n.audioPlaybackChannel, isNotEmpty);
        expect(l10n.localeName, locale);
      });
    });
  }

  group('icuArguments', () {
    test('finds simple and plural arguments', () {
      expect(icuArguments('Hi {name}, {n, plural, =1{one} other{{n} x}}'), {
        'name',
        'n',
      });
    });

    for (final bad in [
      'Hi {name',
      '{n, plural, =1{one}}',
      '{n, plural, other{x}',
      '{n, plural, lots{x} other{y}}',
      '{n, gender, other{x}}',
      'stray }',
    ]) {
      test('rejects "$bad"', () {
        expect(() => icuArguments(bad), throwsFormatException);
      });
    }
  });
}

/// The argument names in an ICU [message] (simple `{name}` arguments and
/// the selectors of plurals and selects). Throws a [FormatException] for
/// unbalanced braces, unknown plural categories or a missing `other`.
Set<String> icuArguments(String message) {
  final names = <String>{};
  var i = 0;

  Never fail(String why) => throw FormatException(why, message, i);

  String readUntil(Set<String> stops) {
    final start = i;
    while (i < message.length && !stops.contains(message[i])) {
      i++;
    }
    if (i >= message.length) fail('unclosed {');
    return message.substring(start, i).trim();
  }

  // Reads text up to the end of the message, or up to the `}` closing a
  // branch when [nested].
  void text({required bool nested}) {
    while (i < message.length) {
      final c = message[i];
      if (c == '}') {
        if (nested) return;
        fail('stray }');
      }
      i++;
      if (c != '{') continue;
      final name = readUntil({',', '}'});
      if (!RegExp(r'^[A-Za-z_]\w*$').hasMatch(name)) fail('bad name "$name"');
      names.add(name);
      if (message[i++] == '}') continue;
      final kind = readUntil({','});
      i++;
      if (kind != 'plural' && kind != 'select') fail('unknown type $kind');
      final branches = <String>{};
      while (true) {
        final selector = readUntil({'{', '}'});
        if (message[i] == '}') {
          if (selector.isNotEmpty) fail('branch without a message');
          i++;
          break;
        }
        if (kind == 'plural' &&
            !RegExp(
              r'^(zero|one|two|few|many|other|=\d+)$',
            ).hasMatch(selector)) {
          fail('bad plural category "$selector"');
        }
        if (!branches.add(selector)) fail('duplicate branch $selector');
        i++;
        text(nested: true);
        if (i >= message.length) fail('unclosed branch');
        i++;
      }
      if (!branches.contains('other')) fail('no other branch');
    }
    if (nested) fail('unclosed branch');
  }

  text(nested: false);
  return names;
}
