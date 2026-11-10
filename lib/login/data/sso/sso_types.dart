import 'package:abs_wear/login/data/sso/sso_http.dart';

/// Redirect URI the server admin allows for ABS Wear under Settings →
/// Authentication → Allowed Mobile Redirect URIs. Nothing ever opens it:
/// the watch reads the code from the redirect itself.
const ssoRedirectUri = 'abswear://oauth';

/// What a field on an SSO login screen asks for.
enum SsoField { username, email, password, code }

/// The next thing the user has to do on the watch.
sealed class SsoStep {
  const SsoStep();
}

/// Fill in [fields] (in this order). [user] is the account being logged in,
/// once the identity provider knows it. [retry] means the last answer was
/// wrong (a wrong password or code).
class SsoPrompt extends SsoStep {
  const SsoPrompt(this.fields, {this.user, this.retry = false});

  final List<SsoField> fields;
  final String? user;
  final bool retry;
}

/// Allow [app] to use the account (the identity provider's consent screen).
class SsoConsent extends SsoStep {
  const SsoConsent(this.app);

  final String app;
}

/// Nothing to type: the user approves the sign-in elsewhere (a push on
/// their phone, or [code] entered on another device at [url]). The screen
/// sends an empty answer every [poll] until the identity provider moves on.
class SsoWait extends SsoStep {
  const SsoWait({this.code, this.url, this.poll = const Duration(seconds: 3)});

  final String? code;
  final Uri? url;
  final Duration poll;
}

/// Logged in: [data] is the server's login response, the same as for
/// password login (`user`, `userDefaultLibraryId`, ...).
class SsoDone extends SsoStep {
  const SsoDone(this.data);

  final Map<String, dynamic> data;
}

enum SsoError {
  /// The server has no SSO (or is older than ABS 2.7).
  notEnabled,

  /// The server doesn't allow [ssoRedirectUri] yet.
  redirectNotAllowed,

  /// The identity provider's login page isn't one the watch can drive.
  unsupportedProvider,

  /// The identity provider asks for something the watch can't do (passkey,
  /// captcha, a sign-up form).
  unsupportedStep,

  /// The identity provider refused this user for the app.
  accessDenied,

  /// SSO worked, but the user has no Audiobookshelf account.
  noAccount,

  /// Anything else: an unexpected answer, a login that went stale.
  failed,
}

class SsoException implements Exception {
  const SsoException(this.error, [this.detail]);

  final SsoError error;
  final String? detail;

  @override
  String toString() =>
      'SsoException($error${detail == null ? '' : ': $detail'})';
}

/// A page the identity provider showed (after following redirects).
class SsoPage {
  const SsoPage(this.url, this.body);

  final Uri url;

  /// The page's HTML (or JSON), for recognising the identity provider.
  final String body;
}

/// Follows redirects from a URL until a page (first) or the redirect back
/// to the watch (second).
typedef FollowRedirects = Future<(SsoPage?, Uri?)> Function(Uri url);

/// What an adapter works with: the login's HTTP client (with its cookies)
/// and redirect following that stops at the redirect back to the watch.
class IdpContext {
  const IdpContext(this.http, this.follow);

  final SsoHttp http;
  final FollowRedirects follow;
}

/// Makes the adapter for [page] if it is that identity provider's login
/// page, else null. Listed in idp_adapters.dart.
typedef IdpAdapterFactory = IdpAdapter? Function(SsoPage page, IdpContext c);

/// Drives one identity provider's login screens over plain HTTP.
abstract class IdpAdapter {
  /// The identity provider's product name, shown above its screens.
  String get name;

  /// The first screen, starting from the identity provider's [page].
  Future<SsoStep> begin(SsoPage page);

  /// Sends the user's [answer] to the current screen. Returns the next
  /// screen, or null once the identity provider redirects back to
  /// [redirect] (where the caller carries on).
  Future<SsoStep?> submit(Map<SsoField, String> answer);

  /// Where the identity provider sent the browser after the last screen.
  Uri? get redirect;
}
