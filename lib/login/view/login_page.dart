import 'dart:convert';
import 'dart:ui' as ui;

import 'package:audiobookshelfwear/app/app.dart';
import 'package:audiobookshelfwear/l10n/l10n.dart';
import 'package:audiobookshelfwear/library/view/library_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:http/http.dart' as http;

class LoginPage extends StatefulWidget {
  const LoginPage({super.key});

  @override
  LoginPageState createState() => LoginPageState();
}

class LoginPageState extends State<LoginPage> {
  final TextEditingController serverUrlController =
      TextEditingController(text: 'https://');
  final TextEditingController usernameController = TextEditingController();
  final TextEditingController passwordController = TextEditingController();
  String _token = '';
  String defaultLibraryId = '';
  late AppLocalizations l10n;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    l10n = context.l10n;
  }

  @override
  void initState() {
    super.initState();
    // Set the default values for the server url, username and password
    serverUrlController.text = '';
    usernameController.text = '';
    passwordController.text = '';
  }

  Future<String> login(String url, String username, String password) async {
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
      return token;
    } else {
      return '';
    }
  }

  void logout() {
    // set the token to an empty string
    setState(() {
      _token = '';
    });
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: PreferredSize(
        preferredSize: const ui.Size.fromHeight(40),
        child: AppBar(
          title: Center(
            child: SvgPicture.asset(
              'assets/static/ABSx200.svg',
              height: 32,
              colorFilter: ColorFilter.mode(
                theme.colorScheme.onSurface,
                BlendMode.srcIn,
              ),
            ),
          ),
        ),
      ),
      body: SingleChildScrollView(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
          child: _token == ''
              ? _buildLoginForm(theme)
              : _buildLoggedInState(theme),
        ),
      ),
    );
  }

  Widget _buildLoginForm(ThemeData theme) {
    return Column(
      children: [
        TextFormField(
          style: theme.textTheme.labelSmall,
          strutStyle: StrutStyle.fromTextStyle(
            theme.textTheme.labelSmall!,
          ),
          controller: serverUrlController,
          decoration: InputDecoration(
            labelStyle: theme.textTheme.labelSmall,
            prefixStyle: theme.textTheme.labelSmall,
            labelText: l10n.serverUrlLabel,
          ),
        ),
        TextFormField(
          style: theme.textTheme.labelSmall,
          strutStyle: StrutStyle.fromTextStyle(
            theme.textTheme.labelSmall!,
          ),
          controller: usernameController,
          decoration: InputDecoration(
            labelText: l10n.usernameLabel,
            labelStyle: theme.textTheme.labelSmall,
          ),
        ),
        TextFormField(
          style: theme.textTheme.labelSmall,
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

            login(serverUrl, username, password).then((token) {
              if (token != '') {
                setState(() {
                  _token = token;
                });
              }
            });

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
        const SizedBox(height: 8),
      ],
    );
  }

  Widget _buildLoggedInState(ThemeData theme) {
    return Column(
      children: [
        Text(
          l10n.hello(usernameController.text),
          textAlign: TextAlign.center,
          style: theme.textTheme.bodyMedium,
        ),
        Text(
          serverUrlController.text,
          textAlign: TextAlign.center,
          style: theme.textTheme.labelSmall,
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
        Center(
          child: ElevatedButton(
            // make the logout button red
            style: ElevatedButton.styleFrom(
              backgroundColor: theme.colorScheme.error,
            ),
            onPressed: () async {
              logout();
            },
            child: Text(
              l10n.logout,
              style: theme.textTheme.bodyMedium,
            ),
          ),
        ),
        const SizedBox(height: 8),
      ],
    );
  }
}
