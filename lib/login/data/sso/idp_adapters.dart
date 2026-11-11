import 'package:abs_wear/login/data/sso/authelia_adapter.dart';
import 'package:abs_wear/login/data/sso/authentik_adapter.dart';
import 'package:abs_wear/login/data/sso/html_form_adapter.dart';
import 'package:abs_wear/login/data/sso/logto_adapter.dart';
import 'package:abs_wear/login/data/sso/pocketid_adapter.dart';
import 'package:abs_wear/login/data/sso/sso_types.dart';
import 'package:abs_wear/login/data/sso/tinyauth_adapter.dart';
import 'package:abs_wear/login/data/sso/voidauth_adapter.dart';

/// The identity providers the watch can log in to by itself, tried in this
/// order on the provider's first login page. Each recognises its own page
/// (by URL or HTML) and returns null for anyone else's.
final List<IdpAdapterFactory> idpAdapters = [
  AuthentikAdapter.forPage,
  AutheliaAdapter.forPage,
  LogtoAdapter.forPage,
  VoidAuthAdapter.forPage,
  TinyauthAdapter.forPage,
  PocketIdAdapter.forPage,
  // Generic, so after the providers with their own adapters.
  HtmlFormAdapter.forPage,
];
