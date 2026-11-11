import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:abs_wear/app/toast.dart';
import 'package:abs_wear/app/view/crown_scrollbar.dart';
import 'package:abs_wear/l10n/l10n.dart';
import 'package:abs_wear/library/data/json_cache.dart';
import 'package:abs_wear/library/data/library_api.dart';
import 'package:abs_wear/library/view/library_page.dart';
import 'package:abs_wear/login/data/server_login.dart';
import 'package:abs_wear/login/data/sso/phone_auth.dart';
import 'package:abs_wear/login/data/sso/sso_login.dart';
import 'package:abs_wear/player/player.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

class LoginPage extends StatefulWidget {
  const LoginPage({super.key});

  @override
  LoginPageState createState() => LoginPageState();
}

class LoginPageState extends State<LoginPage> {
  final TextEditingController serverUrlController = TextEditingController();
  final TextEditingController usernameController = TextEditingController();
  final TextEditingController passwordController = TextEditingController();
  final _scrollController = ScrollController();
  String _token = '';
  String defaultLibraryId = '';
  bool _loggingIn = false;

  /// True while an explicit logout is still sending progress and deleting
  /// data, so a new login can't start under it.
  bool _loggingOut = false;

  /// Bumped by every login and logout, so a slow session restore that
  /// started earlier can tell it is out of date.
  int _sessionEpoch = 0;

  /// True until saved credentials have been read, so a logged-in user
  /// doesn't see the login form flash on every start.
  bool _checking = true;

  /// Where the logged-out user is: entering the server, choosing how to log
  /// in (when the server offers both), or entering a password.
  _Stage _stage = _Stage.server;

  /// How the entered server lets users log in (after "Next").
  ServerLogin? _serverLogin;

  /// The SSO login in progress and the screen it shows, or null.
  SsoLogin? _sso;
  SsoStep? _ssoStep;

  /// Which of the current SSO screen's fields is shown.
  int _ssoFieldIndex = 0;

  /// The next check while an [SsoWait] is shown.
  Timer? _ssoPoll;

  /// Opens sign-ins on the paired phone (for tests: a fake).
  @visibleForTesting
  static PhoneAuth phoneAuth = const PhoneAuth();

  /// How long the watch waits for a sign-in on the phone.
  static const phoneSignInLimit = Duration(minutes: 3);

  /// The SSO login being finished on the phone, while waiting for it.
  SsoLogin? _phoneSso;

  /// Numbers phone sign-in attempts, so a cancelled one can't touch a newer
  /// one.
  int _phoneAttempt = 0;
  bool _phoneWaiting = false;

  /// The last SSO login stopped at something the watch can't do, so the
  /// phone is offered.
  bool _offerPhone = false;

  /// Why the server check or the last SSO login failed, shown under the
  /// buttons.
  String? _loginError;
  final Map<SsoField, TextEditingController> _ssoInputs = {
    for (final field in SsoField.values) field: TextEditingController(),
  };
  late AppLocalizations l10n;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    l10n = context.l10n;
  }

  @override
  void dispose() {
    serverUrlController.dispose();
    usernameController.dispose();
    passwordController.dispose();
    _scrollController.dispose();
    _ssoPoll?.cancel();
    _sso?.close();
    for (final input in _ssoInputs.values) {
      input.dispose();
    }
    super.dispose();
  }

  @override
  void initState() {
    super.initState();
    serverUrlController.text = 'https://';
    unawaited(_checkToken());
  }

  Future<void> _checkToken() async {
    try {
      await _finishLogout();
      await _restoreSession();
    } on Object catch (e) {
      debugPrint('Could not restore session: $e');
    } finally {
      if (mounted) setState(() => _checking = false);
    }
  }

  Future<void> _restoreSession() async {
    final epoch = _sessionEpoch;
    final prefs = await SharedPreferences.getInstance();
    final savedToken = prefs.getString('token');
    final savedServerUrl = prefs.getString('serverUrl');
    final savedUsername = prefs.getString('username');
    final savedDefaultLibraryId = prefs.getString('defaultLibraryId');
    if (savedToken == null || savedToken.isEmpty || savedServerUrl == null) {
      // Logged out: offer the last server again.
      if (savedServerUrl != null && mounted) {
        setState(() => serverUrlController.text = savedServerUrl);
      }
      return;
    }
    var libraryId = savedDefaultLibraryId ?? '';
    if (libraryId.isEmpty) {
      // Older installs could save a token without a library; resolve one
      // now rather than showing a library that can never load.
      if (mounted) setState(() => _checking = false);
      try {
        libraryId = await _pickLibraryId(savedServerUrl, savedToken) ?? '';
      } on Object catch (e) {
        debugPrint('Could not resolve library: $e');
      }
      // The user may have logged in or out while this was resolving.
      if (!mounted || epoch != _sessionEpoch || _loggingIn) return;
      if (libraryId.isEmpty) return; // Fall back to the login form.
      await prefs.setString('defaultLibraryId', libraryId);
    }
    if (!mounted || epoch != _sessionEpoch || _loggingIn) return;
    warmUp(savedServerUrl, savedToken);
    setState(() {
      _token = savedToken;
      serverUrlController.text = savedServerUrl;
      usernameController.text = savedUsername ?? '';
      defaultLibraryId = libraryId;
    });
  }

  Future<void> _toast(String msg) => showToast(msg, long: true);

  /// [rawUrl] without trailing slashes, or null (after saying so) when it
  /// isn't an http(s) URL.
  Future<String?> _serverUrl(String rawUrl) async {
    // "https://abs.example.com/" and "https://abs.example.com" both work.
    final url = rawUrl.trim().replaceAll(RegExp(r'/+$'), '');
    final uri = Uri.tryParse(url);
    if (uri == null ||
        !(uri.scheme == 'http' || uri.scheme == 'https') ||
        uri.host.isEmpty) {
      await _toast(l10n.invalidUrl);
      return null;
    }
    return url;
  }

  Future<void> login(String rawUrl, String username, String password) async {
    final url = await _serverUrl(rawUrl);
    if (url == null) return;
    _sessionEpoch++;
    setState(() => _loggingIn = true);
    try {
      final response = await http
          .post(
            Uri.parse('$url/login'),
            headers: {'Content-Type': 'application/json'},
            body: jsonEncode({'username': username, 'password': password}),
          )
          .timeout(const Duration(seconds: 20));
      if (response.statusCode == 401) {
        await _toast(l10n.wrongCredentials);
        return;
      }
      if (response.statusCode != 200) {
        // e.g. 404 from a wrong reverse-proxy path, or a 5xx.
        await _toast(l10n.serverError(response.statusCode));
        return;
      }
      final data = jsonDecode(response.body) as Map<String, dynamic>;
      await _completeLogin(url, data, username: username);
    } on TimeoutException {
      await _toast(l10n.serverTimeout);
    } on Object catch (e) {
      // Network errors are Exceptions, but bad responses throw TypeError
      // from the casts above; both should end in a message, not silence.
      debugPrint('Login failed: $e');
      await _toast(l10n.cannotReachServer);
    } finally {
      if (mounted) setState(() => _loggingIn = false);
    }
  }

  /// Saves a login ([data] is the server's login response, from password or
  /// SSO login) and shows the logged-in view. Throws on a malformed [data].
  Future<void> _completeLogin(
    String url,
    Map<String, dynamic> data, {
    required String username,
  }) async {
    final user = data['user'] as Map<String, dynamic>;
    // The legacy token: it doesn't expire, unlike user.accessToken.
    final token = user['token'] as String;
    // The library last picked on the watch by this user, else theirs
    // from the server.
    final picked = (await SharedPreferences.getInstance())
        .getString('pickedLibrary')
        ?.split('\n');
    final libraryId = await _pickLibraryId(
      url,
      token,
      preferred: [
        if (picked != null &&
            picked.length == 3 &&
            picked[0] == url &&
            picked[1] == username)
          picked[2],
        data['userDefaultLibraryId'] as String?,
      ],
    );
    if (libraryId == null) {
      await _toast(l10n.noLibraries);
      return;
    }

    final prefs = await SharedPreferences.getInstance();
    // Some servers hand out the same token on every login: drop a leftover
    // logout of it before saving it, so a kill in between can't make the
    // next start take this new session for that unfinished logout.
    if (prefs.getStringList(_pendingLogoutKey)?.last == token) {
      await prefs.remove(_pendingLogoutKey);
    }
    await prefs.setString('serverUrl', url);
    await prefs.setString('username', username);
    await prefs.setString('token', token);
    await prefs.setString('defaultLibraryId', libraryId);
    // Don't keep passwords in memory once they have done their job.
    passwordController.clear();
    for (final input in _ssoInputs.values) {
      input.clear();
    }
    if (!mounted) return;
    warmUp(url, token);
    setState(() {
      _token = token;
      defaultLibraryId = libraryId;
      serverUrlController.text = url;
      // The field may still hold "alice "; the identity (local progress,
      // caches) must be the trimmed name that was sent and saved.
      usernameController.text = username;
    });
  }

  /// "Next" on the server screen: asks the server how users log in, then
  /// shows the password form, the choice, or starts SSO straight away.
  Future<void> _next(String rawUrl) async {
    final url = await _serverUrl(rawUrl);
    if (url == null) return;
    setState(() {
      _loggingIn = true;
      _loginError = null;
    });
    ServerLogin? server;
    String? error;
    try {
      server = await ServerLogin.fetch(url);
    } on TimeoutException {
      error = l10n.serverTimeout;
    } on ServerStatusException catch (e) {
      error = l10n.serverError(e.statusCode);
    } on Object catch (e) {
      debugPrint('Server check failed: $e');
      error = l10n.cannotReachServer;
    } finally {
      if (mounted) setState(() => _loggingIn = false);
    }
    if (!mounted) return;
    if (server == null) {
      setState(() => _loginError = error);
      return;
    }
    final login = server;
    setState(() {
      // Where the server really is (after an http to https redirect, say):
      // the logins and everything after use that address.
      serverUrlController.text = login.serverUrl;
      _serverLogin = login;
      // SSO started from here comes back to this screen when cancelled.
      _stage = !login.sso
          ? _Stage.username
          : login.password
          ? _Stage.choose
          : _Stage.server;
    });
    if (login.sso && (!login.password || login.ssoAutoLaunch)) {
      await _startSso(login.serverUrl);
    }
  }

  /// One login screen back.
  void _back() => setState(() {
    _loginError = null;
    _offerPhone = false;
    passwordController.clear();
    _stage = switch (_stage) {
      _Stage.password => _Stage.username,
      _Stage.username when _serverLogin?.sso ?? false => _Stage.choose,
      _ => _Stage.server,
    };
  });

  /// Starts an SSO login at [rawUrl]: the identity provider's screens are
  /// then shown one by one (see [_buildSsoStep]).
  Future<void> _startSso(String rawUrl) async {
    final url = await _serverUrl(rawUrl);
    if (url == null) return;
    _sessionEpoch++;
    setState(() {
      _loggingIn = true;
      _loginError = null;
      _offerPhone = false;
    });
    try {
      final (sso, step) = await SsoLogin.start(url);
      if (!mounted) {
        sso.close();
        return;
      }
      _sso = sso;
      await _showSsoStep(step);
    } on Object catch (e) {
      _ssoFailed(e);
    } finally {
      if (mounted) setState(() => _loggingIn = false);
    }
  }

  Future<void> _submitSso(Map<SsoField, String> answer) async {
    final sso = _sso;
    if (sso == null) return;
    setState(() => _loggingIn = true);
    try {
      final next = await sso.submit(answer);
      if (!identical(_sso, sso)) return; // Cancelled meanwhile.
      await _showSsoStep(next);
    } on Object catch (e) {
      if (identical(_sso, sso)) _ssoFailed(e);
    } finally {
      if (mounted) setState(() => _loggingIn = false);
    }
  }

  Future<void> _showSsoStep(SsoStep step) async {
    if (step is SsoDone) {
      final user = step.data['user'] as Map<String, dynamic>;
      await _completeLogin(
        _sso!.serverUrl,
        step.data,
        username: user['username'] as String,
      );
      _endSso();
      return;
    }
    if (!mounted) return;
    setState(() {
      _ssoStep = step;
      _ssoFieldIndex = 0;
      // A retry keeps the username; passwords and codes are typed again.
      _ssoInputs[SsoField.password]!.clear();
      _ssoInputs[SsoField.code]!.clear();
    });
    if (step is SsoWait) _pollSso(step);
  }

  /// While the user approves elsewhere: asks again every [SsoWait.poll].
  void _pollSso(SsoWait step) {
    _ssoPoll?.cancel();
    _ssoPoll = Timer(step.poll, () async {
      final sso = _sso;
      if (sso == null || !identical(_ssoStep, step)) return;
      try {
        final next = await sso.submit(const {});
        // Back was tapped meanwhile.
        if (!identical(_sso, sso)) return;
        // Approved: nothing may be tapped while the login completes.
        if (next is! SsoWait && mounted) setState(() => _loggingIn = true);
        await _showSsoStep(next);
      } on Object catch (e) {
        if (identical(_sso, sso)) _ssoFailed(e);
      } finally {
        if (mounted && _loggingIn) setState(() => _loggingIn = false);
      }
    });
  }

  /// The username or email typed on an earlier screen of [step], once the
  /// user has moved past it; null when there is none.
  String? _typedIdentifier(SsoPrompt step) {
    for (final field in step.fields.take(_ssoFieldIndex)) {
      if (field != SsoField.username && field != SsoField.email) continue;
      final typed = _ssoInputs[field]!.text.trim();
      if (typed.isNotEmpty) return typed;
    }
    return null;
  }

  /// Back on an SSO screen: the previous field of a multi-field prompt, or
  /// out of the SSO login.
  void _ssoBack() {
    if (_ssoStep is SsoPrompt && _ssoFieldIndex > 0) {
      setState(() => _ssoFieldIndex--);
    } else {
      _endSso();
    }
  }

  /// Ends (or cancels) the SSO login and goes back to the login form.
  void _endSso() {
    _ssoPoll?.cancel();
    _sso?.close();
    _sso = null;
    for (final input in _ssoInputs.values) {
      input.clear();
    }
    if (mounted) setState(() => _ssoStep = null);
  }

  void _ssoFailed(Object error) {
    // The details can hold sign-in URLs (codes, states): debug builds only.
    if (kDebugMode) debugPrint('SSO login failed: $error');
    _endSso();
    final message = switch (error) {
      SsoException(error: SsoError.notEnabled) => l10n.ssoNotEnabled,
      SsoException(error: SsoError.redirectNotAllowed) =>
        l10n.ssoRedirectNotAllowed(ssoRedirectUri),
      SsoException(
        error: SsoError.unsupportedProvider || SsoError.unsupportedStep,
      ) =>
        l10n.ssoUnsupported,
      SsoException(error: SsoError.accessDenied) => l10n.ssoAccessDenied,
      SsoException(error: SsoError.noAccount) => l10n.ssoNoAccount,
      SsoException() => l10n.ssoFailed,
      // A response the adapter didn't expect, not a network problem.
      TypeError() || FormatException() => l10n.ssoFailed,
      TimeoutException() => l10n.serverTimeout,
      _ => l10n.cannotReachServer,
    };
    final offerPhone =
        error is SsoException &&
        (error.error == SsoError.unsupportedProvider ||
            error.error == SsoError.unsupportedStep) &&
        !_phoneCantCarry(error);
    if (mounted) {
      setState(() {
        _loginError = message;
        _offerPhone = offerPhone;
      });
    }
  }

  /// Microsoft's codes (about 2 KB) don't fit through Google's relay for
  /// watches, which cuts addresses after 2046 characters (#82): offering
  /// the phone would only end in a 3-minute wait. Unless the experiment
  /// sends the sign-in straight to the companion app instead.
  bool _phoneCantCarry(SsoException error) {
    if (phoneAuth.redirectBase.isNotEmpty) return false;
    final host = Uri.tryParse(error.detail ?? '')?.host ?? '';
    return const {
      'login.microsoftonline.com',
      'login.microsoft.com',
      'login.live.com',
    }.contains(host);
  }

  /// "Continue on phone": the same SSO login, finished in the paired
  /// phone's browser. The watch makes the server call first (and keeps its
  /// session), the phone opens the identical link, and its answer comes
  /// back here for the code exchange.
  Future<void> _continueOnPhone() async {
    final url = await _serverUrl(serverUrlController.text);
    if (url == null || !mounted) return;
    _sessionEpoch++;
    // Back (or a newer attempt) bumps this: an older attempt still waiting
    // for the server or the phone then gives up without touching anything.
    final attempt = ++_phoneAttempt;
    bool current() => mounted && attempt == _phoneAttempt;
    setState(() {
      _loginError = null;
      _offerPhone = false;
      _phoneWaiting = true;
    });
    SsoLogin? sso;
    var redirect = '';
    try {
      redirect = await phoneAuth.redirectUri();
      if (!current()) return;
      final (login, start) = await SsoLogin.startOnPhone(
        url,
        redirectUri: redirect,
      );
      sso = login;
      if (!current()) return;
      _phoneSso = login;
      final response = await phoneAuth
          .authorize(start)
          // The watch can't tell a sign-in still going from one that got
          // stuck on the phone, so it stops waiting after a while.
          .timeout(
            phoneSignInLimit,
            onTimeout: () => throw const _PhoneTimedOut(),
          );
      if (!current()) return;
      setState(() => _loggingIn = true);
      final done = await login.finishOnPhone(response);
      if (!current() || done is! SsoDone) return;
      final user = done.data['user'] as Map<String, dynamic>;
      await _completeLogin(
        url,
        done.data,
        username: user['username'] as String,
      );
    } on Object catch (e) {
      if (current()) {
        if (e is _PhoneTimedOut) unawaited(_cancelPhoneRequest());
        _phoneFailed(e, redirect);
      }
    } finally {
      sso?.close();
      if (current()) {
        _phoneSso = null;
        setState(() {
          _phoneWaiting = false;
          _loggingIn = false;
        });
      }
    }
  }

  /// Back while waiting for the phone.
  void _cancelPhone() {
    _phoneAttempt++;
    _phoneSso?.close();
    _phoneSso = null;
    unawaited(_cancelPhoneRequest());
    setState(() {
      _phoneWaiting = false;
      _loggingIn = false;
      // Back where it was offered, ready to try again.
      _offerPhone = true;
    });
  }

  Future<void> _cancelPhoneRequest() async {
    try {
      await phoneAuth.cancel();
    } on Object catch (e) {
      if (kDebugMode) debugPrint('Could not cancel the phone sign-in: $e');
    }
  }

  void _phoneFailed(Object error, String redirect) {
    if (kDebugMode) debugPrint('Phone sign-in failed: $error');
    final noPassword = !(_serverLogin?.password ?? true);
    final message = switch (error) {
      PhoneAuthException(error: PhoneAuthError.cancelled) => null,
      PhoneAuthException(error: PhoneAuthError.unsupported) =>
        l10n.ssoPhoneUnsupported,
      PhoneAuthException(error: PhoneAuthError.phoneUnavailable) =>
        noPassword
            ? l10n.ssoPhoneUnavailableNoPassword
            : l10n.ssoPhoneUnavailable,
      PhoneAuthException() => l10n.ssoFailed,
      _PhoneTimedOut() => l10n.ssoPhoneTimedOut,
      SsoException(error: SsoError.redirectNotAllowed) =>
        l10n.ssoRedirectNotAllowed(redirect),
      SsoException(error: SsoError.notEnabled) => l10n.ssoNotEnabled,
      SsoException(error: SsoError.noAccount) => l10n.ssoNoAccount,
      SsoException() || TypeError() || FormatException() => l10n.ssoFailed,
      TimeoutException() => l10n.serverTimeout,
      _ => l10n.cannotReachServer,
    };
    // Worth another go: the phone timed out or was cancelled there, or
    // something went wrong on the way. Not when it can't work at all.
    final retry = switch (error) {
      _PhoneTimedOut() => true,
      PhoneAuthException(
        error: PhoneAuthError.cancelled || PhoneAuthError.failed,
      ) =>
        true,
      PhoneAuthException() => false,
      SsoException(
        error: SsoError.redirectNotAllowed ||
            SsoError.notEnabled ||
            SsoError.noAccount,
      ) =>
        false,
      _ => true,
    };
    if (mounted) {
      setState(() {
        _loginError = message;
        _offerPhone = retry;
      });
    }
  }

  /// The user's saved library if it still exists, otherwise the first book
  /// library (or podcast library if there are no books). Null when none.
  Future<String?> _pickLibraryId(
    String url,
    String token, {
    List<String?> preferred = const [],
  }) async {
    final response = await http
        .get(
          Uri.parse('$url/api/libraries'),
          headers: {'Authorization': 'Bearer $token'},
        )
        .timeout(const Duration(seconds: 20));
    if (response.statusCode != 200) return null;
    final body = jsonDecode(response.body) as Map<String, dynamic>;
    final libraries = (body['libraries'] as List)
        .cast<Map<String, dynamic>>()
        .where((l) => l['mediaType'] == 'book' || l['mediaType'] == 'podcast')
        .toList();
    for (final id in preferred) {
      if (id != null && libraries.any((l) => l['id'] == id)) return id;
    }
    final books = libraries.where((l) => l['mediaType'] == 'book');
    final pick = books.isNotEmpty ? books.first : libraries.firstOrNull;
    return pick?['id'] as String?;
  }

  /// Server and token of an explicit logout whose token isn't revoked yet.
  /// Set before the saved token is removed, so a logout cut short (the app
  /// killed meanwhile) is finished on the next start.
  static const _pendingLogoutKey = 'pendingLogout';

  /// Forgets the session. With [deleteDownloads] (an explicit logout) the
  /// server is told to end the session (best effort; legacy API tokens may
  /// stay valid) and downloaded books are removed from the watch.
  Future<void> logout({bool deleteDownloads = false}) async {
    _sessionEpoch++;
    final token = _token;
    final url = serverUrlController.text;
    final user = usernameController.text;
    final prefs = await SharedPreferences.getInstance();
    passwordController.clear();
    if (deleteDownloads && token.isNotEmpty) {
      await prefs.setStringList(_pendingLogoutKey, [url, token]);
    }
    await prefs.remove('token');
    await prefs.remove('defaultLibraryId');
    if (mounted) {
      setState(() {
        _token = '';
        defaultLibraryId = '';
        _loggingOut = deleteDownloads;
        _stage = _Stage.server;
      });
    }
    if (!deleteDownloads) return;
    try {
      await prefs.remove('pickedLibrary');
      // First, so the push below can't hold it up: the login form already
      // shows, and the next user mustn't find this account's books. The push
      // reads only offline_progress (support directory), not the downloads.
      await _deleteDownloadsAndCache();
      // Progress made offline may not have reached the server yet (e.g. the
      // library wasn't opened since): send it while the token still works.
      // Bounded, so logging out without a connection doesn't hang.
      if (token.isNotEmpty) {
        await AudioPlayerController.pushLocalProgress(
          url,
          token,
          user,
        ).timeout(const Duration(seconds: 15), onTimeout: () {});
      }
      unawaited(_revokeAndForget(prefs, url, token));
      // What still couldn't be sent stays for this user's next login rather
      // than being lost; other accounts never read it.
      await AudioPlayerController.clearAllLocalProgress(keepPending: true);
    } finally {
      if (mounted) setState(() => _loggingOut = false);
    }
  }

  static Future<void> _deleteDownloadsAndCache() async {
    try {
      final docs = await getApplicationDocumentsDirectory();
      // The documents directory holds only per-book download folders.
      for (final entry in docs.listSync()) {
        if (entry is Directory) entry.deleteSync(recursive: true);
      }
    } on Object catch (e) {
      debugPrint('Could not delete downloads: $e');
    }
    await JsonCache.clear();
  }

  /// Revokes [token], then drops its pending logout (unless a newer logout
  /// replaced it meanwhile).
  Future<void> _revokeAndForget(
    SharedPreferences prefs,
    String url,
    String token,
  ) async {
    await _revokeToken(url, token);
    final pending = prefs.getStringList(_pendingLogoutKey);
    if (pending != null && pending.last == token) {
      await prefs.remove(_pendingLogoutKey);
    }
  }

  /// Finishes an explicit logout the app was killed during. The local
  /// cleanup is redone unless someone logged in since (it had finished by
  /// then: login waits for it). The token being logged out still saved
  /// means the app died before removing it, not a newer login. Unsent
  /// progress stays for that user's next login, as after a finished logout.
  Future<void> _finishLogout() async {
    final prefs = await SharedPreferences.getInstance();
    final pending = prefs.getStringList(_pendingLogoutKey);
    if (pending == null) return;
    if (pending.length != 2) {
      await prefs.remove(_pendingLogoutKey);
      return;
    }
    final saved = prefs.getString('token') ?? '';
    if (saved.isEmpty || saved == pending.last) {
      await prefs.remove('token');
      await prefs.remove('defaultLibraryId');
      await prefs.remove('pickedLibrary');
      await _deleteDownloadsAndCache();
      await AudioPlayerController.clearAllLocalProgress(keepPending: true);
    }
    unawaited(_revokeAndForget(prefs, pending.first, pending.last));
  }

  Future<void> _revokeToken(String url, String token) async {
    if (token.isEmpty) return;
    try {
      await http
          .post(
            Uri.parse('$url/logout'),
            headers: {'Authorization': 'Bearer $token'},
          )
          .timeout(const Duration(seconds: 10));
    } on Object catch (e) {
      debugPrint('Server logout failed: $e');
    }
  }

  Future<void> _confirmLogout() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        // Round screens: use the width, keep content inside the circle.
        insetPadding: const EdgeInsets.symmetric(horizontal: 12),
        contentPadding: const EdgeInsets.fromLTRB(20, 24, 20, 0),
        actionsPadding: const EdgeInsets.only(bottom: 12),
        content: Text(
          l10n.logoutConfirm,
          textAlign: TextAlign.center,
          style: Theme.of(context).textTheme.bodySmall,
        ),
        actionsAlignment: MainAxisAlignment.center,
        actions: [
          IconButton(
            tooltip: l10n.cancel,
            icon: const Icon(Icons.close_rounded),
            onPressed: () => Navigator.pop(context, false),
          ),
          IconButton(
            tooltip: l10n.logout,
            icon: const Icon(Icons.check_rounded),
            onPressed: () => Navigator.pop(context, true),
          ),
        ],
      ),
    );
    if (confirmed ?? false) await logout(deleteDownloads: true);
  }

  Future<void> _openLibrary() async {
    final result = await Navigator.push(
      context,
      MaterialPageRoute<LibraryResult>(
        builder: (context) => LibraryPage(
          serverUrl: serverUrlController.text,
          token: _token,
          libraryId: defaultLibraryId,
          user: usernameController.text,
        ),
      ),
    );
    if (!mounted) return;
    switch (result) {
      case LibraryResult.sessionExpired:
        // Token revoked or expired: log in again, keep the downloads.
        await logout();
        unawaited(_toast(l10n.sessionExpired));
      case LibraryResult.libraryMissing:
        await _reresolveLibrary(failedId: defaultLibraryId);
      case LibraryResult.switchLibrary:
        // The library page saved the new default.
        final prefs = await SharedPreferences.getInstance();
        final id = prefs.getString('defaultLibraryId');
        if (!mounted || id == null) return;
        setState(() => defaultLibraryId = id);
        await _openLibrary();
      case null:
        break;
    }
  }

  /// The saved library was deleted on the server; switch to another one.
  /// Stops if the server offers the same library again (e.g. an old server
  /// without the shelves route), rather than reopening it forever.
  Future<void> _reresolveLibrary({required String failedId}) async {
    String? id;
    try {
      id = await _pickLibraryId(serverUrlController.text, _token);
    } on Object catch (e) {
      debugPrint('Could not resolve library: $e');
    }
    if (!mounted) return;
    if (id == null || id == failedId) {
      unawaited(_toast(id == null ? l10n.noLibraries : l10n.errorLoadingData));
      return;
    }
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('defaultLibraryId', id);
    setState(() => defaultLibraryId = id!);
    await _openLibrary();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    // Swiping back (or the back button) steps back one login screen; on
    // the first screen, and once logged in, it leaves the app as before.
    final canLeave =
        _token != '' ||
        (_stage == _Stage.server && _ssoStep == null && !_phoneWaiting);
    return PopScope(
      canPop: canLeave,
      onPopInvokedWithResult: (didPop, _) {
        if (didPop || _busy) return;
        if (_phoneWaiting) {
          _cancelPhone();
        } else if (_ssoStep != null) {
          _ssoBack();
        } else {
          _back();
        }
      },
      child: CrownScrollbar(
        controller: _scrollController,
        child: Scaffold(
          appBar: PreferredSize(
            preferredSize: const ui.Size.fromHeight(40),
            child: AppBar(
              title: Center(
                child: Image.asset(
                  'assets/static/logo.png',
                  // Fits the 40 dp bar, clear of the round screen's edge.
                  height: 34,
                  cacheHeight: (34 * MediaQuery.devicePixelRatioOf(context))
                      .round(),
                  semanticLabel: 'ABS Wear',
                ),
              ),
            ),
          ),
          // Centred on the round screen, where it is widest; scrolls when
          // large text makes it taller than the screen.
          body: LayoutBuilder(
            builder: (context, constraints) => SingleChildScrollView(
              controller: _scrollController,
              // A little room below, so a long screen's last button scrolls
              // clear of the round edge. Short screens fit without scrolling.
              padding: const EdgeInsets.fromLTRB(16, 4, 16, 16),
              child: ConstrainedBox(
                constraints: BoxConstraints(
                  minHeight: constraints.maxHeight - 20,
                ),
                child: Center(
                  child: _checking
                      ? Padding(
                          padding: const EdgeInsets.all(24),
                          child: CircularProgressIndicator(
                            semanticsLabel: l10n.loading,
                          ),
                        )
                      : _token == '' && _phoneWaiting
                      ? _buildPhoneWait(theme)
                      : _token == '' && _ssoStep != null
                      ? _buildSsoStep(theme)
                      : _token == ''
                      ? _buildLoginForm(theme)
                      : _buildLoggedInState(theme),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildLoginForm(ThemeData theme) => switch (_stage) {
    _Stage.server => _buildServerStep(theme),
    _Stage.choose => _buildChooseStep(theme),
    _Stage.username => _buildUsernameStep(theme),
    _Stage.password => _buildPasswordStep(theme),
  };

  bool get _busy => _loggingIn || _loggingOut;

  /// First screen: just the server. "Next" asks it how users log in.
  Widget _buildServerStep(ThemeData theme) {
    return Column(
      children: [
        TextFormField(
          style: theme.textTheme.labelSmall,
          scrollPadding: const EdgeInsets.all(8),
          strutStyle: StrutStyle.fromTextStyle(theme.textTheme.labelSmall!),
          controller: serverUrlController,
          decoration: InputDecoration(
            labelStyle: theme.textTheme.labelSmall,
            prefixStyle: theme.textTheme.labelSmall,
            labelText: l10n.serverUrlLabel,
          ),
          maxLines: null,
          minLines: 1,
          autocorrect: false,
          keyboardType: TextInputType.visiblePassword, // Disable newline
        ),
        const SizedBox(height: 8),
        ElevatedButton(
          onPressed: _busy
              ? null
              : () {
                  if (serverUrlController.text.trim().isEmpty) {
                    unawaited(_toast(l10n.fillAllFields));
                    return;
                  }
                  unawaited(_next(serverUrlController.text));
                },
          child: _busy ? _buttonSpinner() : Text(l10n.next),
        ),
        ..._loginErrorText(theme),
        ..._phoneOffer(theme),
      ],
    );
  }

  /// The server offers both: log in with a password or with SSO.
  Widget _buildChooseStep(ThemeData theme) {
    final server = _serverLogin;
    return Column(
      children: [
        _serverLabel(theme),
        const SizedBox(height: 8),
        ElevatedButton(
          onPressed: _busy
              ? null
              : () => setState(() {
                  _loginError = null;
                  _stage = _Stage.username;
                }),
          child: Text(l10n.passwordLogin),
        ),
        const SizedBox(height: 4),
        ElevatedButton(
          onPressed: _busy
              ? null
              : () => unawaited(_startSso(serverUrlController.text)),
          child: _busy
              ? _buttonSpinner()
              : Text(
                  server?.ssoButtonText ?? l10n.ssoLogin,
                  textAlign: TextAlign.center,
                ),
        ),
        ..._loginErrorText(theme),
        ..._phoneOffer(theme),
        _backButton(theme),
      ],
    );
  }

  /// Password login, first screen: the username.
  Widget _buildUsernameStep(ThemeData theme) {
    // No server line: it was on the screen before, and the field, button
    // and Back fit the round screen without scrolling.
    return Column(
      children: [
        TextFormField(
          style: theme.textTheme.labelSmall,
          scrollPadding: const EdgeInsets.all(8),
          strutStyle: StrutStyle.fromTextStyle(theme.textTheme.labelSmall!),
          controller: usernameController,
          decoration: InputDecoration(
            labelText: l10n.usernameLabel,
            labelStyle: theme.textTheme.labelSmall,
          ),
          maxLines: null,
          minLines: 1,
          autocorrect: false,
          keyboardType: TextInputType.visiblePassword, // Disable newline
        ),
        const SizedBox(height: 8),
        ElevatedButton(
          onPressed: _busy
              ? null
              : () {
                  if (usernameController.text.trim().isEmpty) {
                    unawaited(_toast(l10n.fillAllFields));
                    return;
                  }
                  setState(() => _stage = _Stage.password);
                },
          child: Text(l10n.next),
        ),
        _backButton(theme),
      ],
    );
  }

  /// Password login, second screen: the password for that username.
  Widget _buildPasswordStep(ThemeData theme) {
    final username = usernameController.text.trim();
    return Column(
      children: [
        Text(
          username,
          textAlign: TextAlign.center,
          style: theme.textTheme.bodySmall,
        ),
        TextFormField(
          style: theme.textTheme.labelSmall,
          scrollPadding: const EdgeInsets.all(8),
          strutStyle: StrutStyle.fromTextStyle(theme.textTheme.labelSmall!),
          controller: passwordController,
          decoration: InputDecoration(
            labelText: l10n.passwordLabel,
            labelStyle: theme.textTheme.labelSmall,
          ),
          obscureText: true,
          autocorrect: false,
          enableSuggestions: false,
        ),
        const SizedBox(height: 8),
        ElevatedButton(
          onPressed: _busy
              ? null
              : () {
                  final password = passwordController.text;
                  if (password.isEmpty) {
                    unawaited(_toast(l10n.fillAllFields));
                    return;
                  }
                  unawaited(
                    login(serverUrlController.text, username, password),
                  );
                },
          child: _busy ? _buttonSpinner() : Text(l10n.login),
        ),
        _backButton(theme),
      ],
    );
  }

  /// The server being logged in to, above the later screens.
  Widget _serverLabel(ThemeData theme) => Padding(
    padding: const EdgeInsets.symmetric(horizontal: 16),
    child: Text(
      // Host (and port) only: the full URL is long on a watch.
      Uri.tryParse(serverUrlController.text)?.authority ??
          serverUrlController.text,
      textAlign: TextAlign.center,
      style: theme.textTheme.labelSmall,
    ),
  );

  Widget _backButton(ThemeData theme) => TextButton(
    onPressed: _busy ? null : _back,
    child: Text(l10n.back, style: theme.textTheme.bodySmall),
  );

  /// "Continue on phone" under an SSO error the watch can't get past.
  List<Widget> _phoneOffer(ThemeData theme) => [
    if (_offerPhone) ...[
      const SizedBox(height: 4),
      ElevatedButton(
        onPressed: _busy ? null : () => unawaited(_continueOnPhone()),
        child: Text(l10n.ssoContinueOnPhone, textAlign: TextAlign.center),
      ),
    ],
  ];

  /// While the sign-in is finished on the phone.
  Widget _buildPhoneWait(ThemeData theme) {
    return Column(
      children: [
        const Icon(Icons.phone_android_rounded, size: 32),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
          child: Text(
            l10n.ssoPhoneWaiting,
            textAlign: TextAlign.center,
            style: theme.textTheme.bodySmall,
          ),
        ),
        SizedBox.square(
          dimension: 24,
          child: CircularProgressIndicator(
            strokeWidth: 2,
            semanticsLabel: l10n.loading,
          ),
        ),
        TextButton(
          onPressed: _loggingIn ? null : _cancelPhone,
          child: Text(l10n.back, style: theme.textTheme.bodySmall),
        ),
      ],
    );
  }

  List<Widget> _loginErrorText(ThemeData theme) => [
    if (_loginError case final error?)
      Padding(
        padding: const EdgeInsets.fromLTRB(8, 8, 8, 0),
        child: Text(
          error,
          textAlign: TextAlign.center,
          style: theme.textTheme.labelSmall!.copyWith(
            color: theme.colorScheme.error,
          ),
        ),
      ),
  ];

  Widget _buttonSpinner() => SizedBox.square(
    dimension: 16,
    child: CircularProgressIndicator(
      strokeWidth: 2,
      semanticsLabel: l10n.loading,
    ),
  );

  /// One screen of an SSO login: the identity provider's fields, or its
  /// consent question.
  Widget _buildSsoStep(ThemeData theme) {
    final step = _ssoStep!;
    final small = theme.textTheme.labelSmall!;
    final busy = _loggingIn;
    final field = step is SsoPrompt ? step.fields[_ssoFieldIndex] : null;
    return Column(
      children: [
        // Who is asking: these are the identity provider's questions.
        if (_sso?.provider case final provider?)
          Text(
            provider,
            textAlign: TextAlign.center,
            style: small.copyWith(color: theme.colorScheme.primary),
          ),
        if (step is SsoPrompt) ...[
          // The account being logged in: from the provider, or as typed on
          // the screen before.
          if (step.user ?? _typedIdentifier(step) case final user?)
            Text(
              user,
              textAlign: TextAlign.center,
              style: theme.textTheme.bodyMedium,
            ),
          if (step.retry && _ssoFieldIndex == 0)
            Text(
              step.fields.contains(SsoField.code)
                  ? l10n.ssoWrongCode
                  : l10n.wrongCredentials,
              textAlign: TextAlign.center,
              style: small.copyWith(color: theme.colorScheme.error),
            ),
          // One field per screen, like password login: the earlier ones
          // are kept until the last is filled in, then all are sent.
          TextFormField(
            key: ValueKey(field),
            style: small,
            scrollPadding: const EdgeInsets.all(8),
            strutStyle: StrutStyle.fromTextStyle(small),
            controller: _ssoInputs[field],
            decoration: InputDecoration(
              labelText: switch (field!) {
                SsoField.username => l10n.usernameLabel,
                SsoField.email => l10n.emailLabel,
                SsoField.password => l10n.passwordLabel,
                SsoField.code => l10n.ssoCodeLabel,
              },
              labelStyle: small,
            ),
            obscureText: field == SsoField.password,
            autocorrect: false,
            enableSuggestions: false,
            // Also for codes: recovery codes can have letters. No newline.
            keyboardType: TextInputType.visiblePassword,
          ),
          const SizedBox(height: 8),
          ElevatedButton(
            onPressed: busy
                ? null
                : () {
                    String value(SsoField f) => f == SsoField.password
                        ? _ssoInputs[f]!.text
                        : _ssoInputs[f]!.text.trim();
                    if (value(field).isEmpty) {
                      unawaited(_toast(l10n.fillAllFields));
                      return;
                    }
                    if (_ssoFieldIndex < step.fields.length - 1) {
                      setState(() => _ssoFieldIndex++);
                      return;
                    }
                    unawaited(
                      _submitSso({for (final f in step.fields) f: value(f)}),
                    );
                  },
            child: busy ? _buttonSpinner() : Text(l10n.next),
          ),
        ] else if (step is SsoWait) ...[
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
            child: Text(
              switch (step.code) {
                final code? => l10n.ssoWaitCode(code),
                null => l10n.ssoWaitApprove,
              },
              textAlign: TextAlign.center,
              style: theme.textTheme.bodySmall,
            ),
          ),
          if (step.url case final url?)
            Text(
              '${url.authority}${url.path == '/' ? '' : url.path}',
              textAlign: TextAlign.center,
              style: small,
            ),
          Padding(
            padding: const EdgeInsets.all(12),
            child: SizedBox.square(
              dimension: 24,
              child: CircularProgressIndicator(
                strokeWidth: 2,
                semanticsLabel: l10n.loading,
              ),
            ),
          ),
        ] else if (step is SsoConsent) ...[
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
            child: Text(
              l10n.ssoConsent(step.app),
              textAlign: TextAlign.center,
              style: theme.textTheme.bodySmall,
            ),
          ),
          ElevatedButton(
            onPressed: busy ? null : () => unawaited(_submitSso(const {})),
            child: busy ? _buttonSpinner() : Text(l10n.ssoAllow),
          ),
        ],
        TextButton(
          onPressed: busy ? null : _ssoBack,
          child: Text(l10n.back, style: theme.textTheme.bodySmall),
        ),
      ],
    );
  }

  Widget _buildLoggedInState(ThemeData theme) {
    return Column(
      children: [
        const SizedBox(height: 8),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: Text(
            l10n.hello(usernameController.text),
            textAlign: TextAlign.center,
            style: theme.textTheme.bodyMedium,
          ),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: Text(
            serverUrlController.text,
            textAlign: TextAlign.center,
            style: theme.textTheme.labelSmall,
          ),
        ),
        ElevatedButton(
          onPressed: () => unawaited(_openLibrary()),
          child: Text(l10n.library),
        ),
        const SizedBox(height: 8),
        Center(
          child: ElevatedButton(
            style: ElevatedButton.styleFrom(
              backgroundColor: theme.colorScheme.error,
            ),
            onPressed: () => unawaited(_confirmLogout()),
            // Dark text: white on the error red is too faint to read.
            child: Text(
              l10n.logout,
              style: theme.textTheme.bodyMedium!.copyWith(
                color: theme.colorScheme.onError,
              ),
            ),
          ),
        ),
        const SizedBox(height: 32),
      ],
    );
  }
}

/// The logged-out screens, one question each.
enum _Stage { server, choose, username, password }

/// The watch stopped waiting for the sign-in on the phone
/// ([LoginPageState.phoneSignInLimit]).
class _PhoneTimedOut implements Exception {
  const _PhoneTimedOut();
}
