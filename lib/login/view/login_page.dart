import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:abs_wear/app/view/crown_scrollbar.dart';
import 'package:abs_wear/l10n/l10n.dart';
import 'package:abs_wear/library/data/json_cache.dart';
import 'package:abs_wear/library/view/library_page.dart';
import 'package:abs_wear/player/player.dart';
import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:fluttertoast/fluttertoast.dart';
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

  /// Bumped by every login and logout, so a slow session restore that
  /// started earlier can tell it is out of date.
  int _sessionEpoch = 0;

  /// True until saved credentials have been read, so a logged-in user
  /// doesn't see the login form flash on every start.
  bool _checking = true;
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
    setState(() {
      _token = savedToken;
      serverUrlController.text = savedServerUrl;
      usernameController.text = savedUsername ?? '';
      defaultLibraryId = libraryId;
    });
  }

  Future<void> _toast(String msg) => Fluttertoast.showToast(
    msg: msg,
    toastLength: Toast.LENGTH_LONG,
    gravity: ToastGravity.CENTER,
  );

  Future<void> login(String rawUrl, String username, String password) async {
    // "https://abs.example.com/" and "https://abs.example.com" both work.
    final url = rawUrl.trim().replaceAll(RegExp(r'/+$'), '');
    final uri = Uri.tryParse(url);
    if (uri == null ||
        !(uri.scheme == 'http' || uri.scheme == 'https') ||
        uri.host.isEmpty) {
      await _toast(l10n.invalidUrl);
      return;
    }
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
      final user = data['user'] as Map<String, dynamic>;
      final token = user['token'] as String;
      final libraryId = await _pickLibraryId(
        url,
        token,
        preferred: data['userDefaultLibraryId'] as String?,
      );
      if (libraryId == null) {
        await _toast(l10n.noLibraries);
        return;
      }

      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('serverUrl', url);
      await prefs.setString('username', username);
      await prefs.setString('token', token);
      await prefs.setString('defaultLibraryId', libraryId);
      // Don't keep the password in memory once it has done its job.
      passwordController.clear();
      if (!mounted) return;
      setState(() {
        _token = token;
        defaultLibraryId = libraryId;
        serverUrlController.text = url;
      });
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

  /// The user's saved library if it still exists, otherwise the first book
  /// library (or podcast library if there are no books). Null when none.
  Future<String?> _pickLibraryId(
    String url,
    String token, {
    String? preferred,
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
    if (preferred != null && libraries.any((l) => l['id'] == preferred)) {
      return preferred;
    }
    final books = libraries.where((l) => l['mediaType'] == 'book');
    final pick = books.isNotEmpty ? books.first : libraries.firstOrNull;
    return pick?['id'] as String?;
  }

  /// Forgets the session. With [deleteDownloads] (an explicit logout) the
  /// server is told to end the session (best effort; legacy API tokens may
  /// stay valid) and downloaded books are removed from the watch.
  Future<void> logout({bool deleteDownloads = false}) async {
    _sessionEpoch++;
    final token = _token;
    final url = serverUrlController.text;
    final prefs = await SharedPreferences.getInstance();
    passwordController.clear();
    await prefs.remove('token');
    await prefs.remove('defaultLibraryId');
    if (mounted) {
      setState(() {
        _token = '';
        defaultLibraryId = '';
      });
    }
    if (!deleteDownloads) return;
    unawaited(_revokeToken(url, token));
    await JsonCache.clear();
    await AudioPlayerController.clearAllLocalProgress();
    try {
      final docs = await getApplicationDocumentsDirectory();
      // The documents directory holds only per-book download folders.
      for (final entry in docs.listSync()) {
        if (entry is Directory) entry.deleteSync(recursive: true);
      }
    } on Object catch (e) {
      debugPrint('Could not delete downloads: $e');
    }
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
    return CrownScrollbar(
      controller: _scrollController,
      child: Scaffold(
        appBar: PreferredSize(
          preferredSize: const ui.Size.fromHeight(40),
          child: AppBar(
            title: Center(
              child: SvgPicture.asset(
                'assets/static/ABSWear_round.svg',
                height: 45,
                colorFilter: ColorFilter.mode(
                  theme.colorScheme.onSurface,
                  BlendMode.srcIn,
                ),
              ),
            ),
          ),
        ),
        body: ListView(
          controller: _scrollController,
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          children: [
            if (_checking)
              const Padding(
                padding: EdgeInsets.all(24),
                child: Center(child: CircularProgressIndicator()),
              )
            else if (_token == '')
              _buildLoginForm(theme)
            else
              _buildLoggedInState(theme),
          ],
        ),
      ),
    );
  }

  Widget _buildLoginForm(ThemeData theme) {
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
          onPressed: _loggingIn
              ? null
              : () {
                  final serverUrl = serverUrlController.text;
                  final username = usernameController.text.trim();
                  final password = passwordController.text;
                  if (serverUrl.isEmpty ||
                      username.isEmpty ||
                      password.isEmpty) {
                    unawaited(_toast(l10n.fillAllFields));
                    return;
                  }
                  unawaited(login(serverUrl, username, password));
                },
          child: _loggingIn
              ? const SizedBox.square(
                  dimension: 16,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : Text(l10n.login, style: theme.textTheme.bodyMedium),
        ),
        const SizedBox(height: 16),
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
          child: Text(l10n.library, style: theme.textTheme.bodyMedium),
        ),
        const SizedBox(height: 8),
        Center(
          child: ElevatedButton(
            style: ElevatedButton.styleFrom(
              backgroundColor: theme.colorScheme.error,
            ),
            onPressed: () => unawaited(_confirmLogout()),
            child: Text(l10n.logout, style: theme.textTheme.bodyMedium),
          ),
        ),
        const SizedBox(height: 32),
      ],
    );
  }
}
