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
