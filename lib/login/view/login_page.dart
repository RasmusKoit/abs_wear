// ignore_for_file: avoid_dynamic_calls

import 'dart:convert';
import 'dart:ui' as ui;

import 'package:abs_wear/l10n/l10n.dart';
import 'package:abs_wear/library/view/library_page.dart';
import 'package:flutter/foundation.dart';
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
    _checkToken();
  }

  Future<void> _checkToken() async {
    final prefs = await SharedPreferences.getInstance();
    final savedToken = prefs.getString('token');
    final savedServerUrl = prefs.getString('serverUrl');
    final savedUsername = prefs.getString('username');
    final savedDefaultLibraryId = prefs.getString('defaultLibraryId');
    if (savedToken != null && savedToken.isNotEmpty) {
      setState(() {
        _token = savedToken;
        serverUrlController.text = savedServerUrl!;
        usernameController.text = savedUsername!;
        defaultLibraryId = savedDefaultLibraryId!;
      });
    }
  }

  Future<void> login(String url, String username, String password) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('serverUrl', url);
      await prefs.setString('username', username);
      final response = await http.post(
        Uri.parse('$url/login'),
        headers: <String, String>{
          'Content-Type': 'application/json',
        },
        body: jsonEncode(<String, String>{
          'username': username,
          'password': password,
        }),
      );

      if (response.statusCode == 200) {
        final data = jsonDecode(response.body) as Map<String, dynamic>;
        final token = data['user']['token'] as String;
        defaultLibraryId = data['userDefaultLibraryId'] as String;

        await prefs.setString('token', token);
        await prefs.setString('defaultLibraryId', defaultLibraryId);
        setState(() {
          _token = token;
        });
      } else {
        await Fluttertoast.showToast(
          msg: 'Wrong username or password.',
          toastLength: Toast.LENGTH_SHORT,
          gravity: ToastGravity.CENTER,
        );
      }
    } catch (e) {
      // Show an error message
      if (kDebugMode) {
        print(e);
      }
      await Fluttertoast.showToast(
        msg: 'Error with URL',
        toastLength: Toast.LENGTH_SHORT,
        gravity: ToastGravity.CENTER,
      );
    }
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
    return RotaryScrollWrapper(
      rotaryScrollbar: RotaryScrollbar(
        width: 2,
        padding: 1,
        hasHapticFeedback: false,
        autoHide: false,
        controller: _pageController,
      ),
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
          strutStyle: StrutStyle.fromTextStyle(
            theme.textTheme.labelSmall!,
          ),
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
          strutStyle: StrutStyle.fromTextStyle(
            theme.textTheme.labelSmall!,
          ),
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
          strutStyle: StrutStyle.fromTextStyle(
            theme.textTheme.labelSmall!,
          ),
          controller: passwordController,
          decoration: InputDecoration(
            labelText: l10n.passwordLabel,
            labelStyle: theme.textTheme.labelSmall,
          ),
          obscureText: true,
        ),
        const SizedBox(height: 8),
        ElevatedButton(
          onPressed: () {
            final serverUrl = serverUrlController.text;
            final username = usernameController.text;
            final password = passwordController.text;

            if (serverUrl.isEmpty || username.isEmpty || password.isEmpty) {
              // Show an error message
              return;
            }

            login(serverUrl, username, password);

            if (_token == '') {
              // Show an error message
              return;
            }
          },
          child: Text(
            l10n.login,
            style: theme.textTheme.bodyMedium,
          ),
        ),
        const SizedBox(height: 16),
      ],
    );
  }

  Widget _buildLoggedInState(ThemeData theme) {
    _pageController.jumpTo(0.1);
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
          child: Text(
            l10n.library,
            style: theme.textTheme.bodyMedium,
          ),
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
            child: Text(
              l10n.logout,
              style: theme.textTheme.bodyMedium,
            ),
          ),
        ),
        const SizedBox(height: 32),
      ],
    );
  }
}
