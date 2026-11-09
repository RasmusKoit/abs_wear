import 'dart:ui' show PlatformDispatcher;

import 'package:abs_wear/l10n/gen/app_localizations.dart';
import 'package:flutter/widgets.dart';

export 'package:abs_wear/l10n/gen/app_localizations.dart';

extension AppLocalizationsX on BuildContext {
  AppLocalizations get l10n => AppLocalizations.of(this);
}

/// The strings for the device's language, resolved as MaterialApp does.
/// For text needed before there is a [BuildContext], such as the media
/// notification channel's name set up in `main`.
AppLocalizations deviceL10n() => lookupAppLocalizations(
  basicLocaleListResolution(
    PlatformDispatcher.instance.locales,
    AppLocalizations.supportedLocales,
  ),
);

extension SpokenDuration on AppLocalizations {
  /// [duration] in words, for screen readers, which read "01:06:40" digit
  /// by digit or as a time of day: "1 hour 6 minutes", "6 minutes 40
  /// seconds". Seconds only under an hour, and not at all without
  /// [seconds] (for displays that show minutes only).
  String spokenDuration(Duration duration, {bool seconds = true}) {
    final h = duration.inHours;
    final m = duration.inMinutes % 60;
    final s = seconds && h == 0 ? duration.inSeconds % 60 : 0;
    return [
      if (h > 0) hoursCount(h),
      if (m > 0 || (h == 0 && s == 0)) minutesCount(m),
      if (s > 0) secondsCount(s),
    ].join(' ');
  }
}
