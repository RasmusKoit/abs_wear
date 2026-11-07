import 'dart:async';
import 'dart:convert';
import 'dart:ui' as ui;

import 'package:abs_wear/l10n/l10n.dart';
import 'package:abs_wear/library/view/library_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:fluttertoast/fluttertoast.dart';
import 'package:http/http.dart' as http;
import 'package:rotary_scrollbar/rotary_scrollbar.dart';
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
  final _pageController = PageController();
  String _token = '';
  String defaultLibraryId = '';
  bool _loggingIn = false;
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
    _pageController.dispose();
    super.dispose();
  }

  @override
  void initState() {
    super.initState();
    serverUrlController.text = 'https://';
    unawaited(_checkToken());
  }

  Future<void> _checkToken() async {
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
      try {
        libraryId = await _firstLibraryId(savedServerUrl, savedToken) ?? '';
      } on Object catch (e) {
        debugPrint('Could not resolve library: $e');
      }
      if (libraryId.isEmpty) return; // Fall back to the login form.
      await prefs.setString('defaultLibraryId', libraryId);
    }
    if (!mounted) return;
    setState(() {
      _token = savedToken;
      serverUrlController.text = savedServerUrl;
      usernameController.text = savedUsername ?? '';
      defaultLibraryId = libraryId;
    });
  }

  Future<void> _toast(String msg) => Fluttertoast.showToast(
    msg: msg,
    toastLength: Toast.LENGTH_SHORT,
    gravity: ToastGravity.CENTER,
  );

  Future<void> login(String rawUrl, String username, String password) async {
    // "https://abs.example.com/" and "https://abs.example.com" both work.
    final url = rawUrl.trim().replaceAll(RegExp(r'/+$'), '');
    final uri = Uri.tryParse(url);
    if (uri == null ||
        !(uri.scheme == 'http' || uri.scheme == 'https') ||
        uri.host.isEmpty) {
      await _toast('Enter a full URL, e.g. https://abs.example.com');
      return;
    }
    setState(() => _loggingIn = true);
    try {
      final response = await http
          .post(
            Uri.parse('$url/login'),
            headers: {'Content-Type': 'application/json'},
            body: jsonEncode({'username': username, 'password': password}),
          )
          .timeout(const Duration(seconds: 20));
      if (response.statusCode != 200) {
        await _toast('Wrong username or password.');
        return;
      }
      final data = jsonDecode(response.body) as Map<String, dynamic>;
      final user = data['user'] as Map<String, dynamic>;
      final token = user['token'] as String;
      // Users without a default library (e.g. root) get the first one.
      final libraryId =
          data['userDefaultLibraryId'] as String? ??
          await _firstLibraryId(url, token);
      if (libraryId == null) {
        await _toast('No libraries on this server.');
        return;
      }

      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('serverUrl', url);
      await prefs.setString('username', username);
      await prefs.setString('token', token);
      await prefs.setString('defaultLibraryId', libraryId);
      if (!mounted) return;
      setState(() {
        _token = token;
        defaultLibraryId = libraryId;
        serverUrlController.text = url;
      });
    } on Object catch (e) {
      // Network errors are Exceptions, but bad responses throw TypeError
      // from the casts above; both should end in a message, not silence.
      debugPrint('Login failed: $e');
      await _toast('Error with URL');
    } finally {
      if (mounted) setState(() => _loggingIn = false);
    }
  }

  Future<String?> _firstLibraryId(String url, String token) async {
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
        .where((l) => l['mediaType'] == 'book');
    return libraries.isEmpty ? null : libraries.first['id'] as String;
  }

  Future<void> logout() async {
    final prefs = await SharedPreferences.getInstance();
    passwordController.clear();
    await prefs.remove('token');
    // set the token to an empty string
    setState(() {
      _token = '';
    });
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return RotaryScrollbar(
      width: 2,
      padding: 1,
      hasHapticFeedback: false,
      autoHide: false,
      controller: _pageController,
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
          controller: _pageController,
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          children: [
            if (_token == '')
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
                    unawaited(_toast('Fill in all fields.'));
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
          onPressed: () {
            Navigator.push(
              context,
              MaterialPageRoute<LibraryPage>(
                builder: (context) => LibraryPage(
                  serverUrl: serverUrlController.text,
                  token: _token,
                  libraryId: defaultLibraryId,
                  user: usernameController.text,
                ),
              ),
            );
          },
          child: Text(l10n.library, style: theme.textTheme.bodyMedium),
        ),
        const SizedBox(height: 8),
        Center(
          child: ElevatedButton(
            // make the logout button red
            style: ElevatedButton.styleFrom(
              backgroundColor: theme.colorScheme.error,
            ),
            onPressed: () async {
              await logout();
            },
            child: Text(l10n.logout, style: theme.textTheme.bodyMedium),
          ),
        ),
        const SizedBox(height: 32),
      ],
    );
  }
}
