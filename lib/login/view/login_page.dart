import 'dart:convert';
import 'dart:ui' as ui;

import 'package:audiobookshelfwear/l10n/l10n.dart';
import 'package:audiobookshelfwear/library/view/library_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:http/http.dart' as http;

class LoginPage extends StatefulWidget {
  const LoginPage({super.key});

  @override
  _LoginPageState createState() => _LoginPageState();
}

class _LoginPageState extends State<LoginPage> {
  final TextEditingController serverUrlController =
      TextEditingController(text: 'https://');
  final TextEditingController usernameController = TextEditingController();
  final TextEditingController passwordController = TextEditingController();
  late String _token = '';
  String defaultLibraryId = '';

  Future<String?> login(String url, String username, String password) async {
    var response = await http.post(
      Uri.parse('${url}/login'),
      headers: <String, String>{
        'Content-Type': 'application/json',
      },
      body: jsonEncode(<String, String>{
        'username': username,
        'password': password,
      }),
    );

    if (response.statusCode == 200) {
      print('Login successful');
      final data = jsonDecode(response.body) as Map<String, dynamic>;
      final token = data['user']['token'] as String;
      defaultLibraryId = data['userDefaultLibraryId'] as String;

      // Save the token and use it  for subsequent API calls
      // Navigate to the next screen
      // Navigator.push(context, MaterialPageRoute(builder: (context) => NextScreen()));
      return token;
    } else {
      print('Login failed');
      return null;
      // Show an error message
    }
  }

  Future<void> logout() async {
    // Perform logout logic here
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
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
              ? Column(
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
                        labelText: 'Server URL',
                      ),
                    ),
                    TextFormField(
                      style: theme.textTheme.labelSmall,
                      strutStyle: StrutStyle.fromTextStyle(
                        theme.textTheme.labelSmall!,
                      ),
                      controller: usernameController,
                      decoration: InputDecoration(
                        labelText: 'Username',
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
                        labelText: 'Password',
                        labelStyle: theme.textTheme.labelSmall,
                      ),
                      obscureText: true,
                    ),
                    const SizedBox(height: 8),
                    ElevatedButton(
                      onPressed: () {
                        // Perform login logic here
                        final serverUrl = serverUrlController.text;
                        final username = usernameController.text;
                        final password = passwordController.text;

                        if (serverUrl.isEmpty ||
                            username.isEmpty ||
                            password.isEmpty) {
                          // Show an error message
                          return;
                        }
                        login(serverUrl, username, password).then((token) {
                          if (token == null) {
                            return;
                          }
                          setState(() {
                            _token = token;
                          });
                          Navigator.push(
                            context,
                            MaterialPageRoute<LibraryPage>(
                              builder: (context) => LibraryPage(
                                serverUrl: serverUrl,
                                token: token,
                                libraryId: defaultLibraryId,
                                user: username,
                              ),
                            ),
                          );
                        });
                      },
                      child: Text(
                        'Login',
                        style: theme.textTheme.bodyMedium,
                      ),
                    ),
                    const SizedBox(height: 8),
                  ],
                )
              : Column(
                  children: [
                    Text(
                      'Hello ${usernameController.text}',
                      textAlign: TextAlign.center,
                      style: theme.textTheme.bodyMedium,
                    ),
                    Text(
                      '${serverUrlController.text}',
                      textAlign: TextAlign.center,
                      style: theme.textTheme.labelSmall,
                    ),
                    Center(
                      child: ElevatedButton(
                        onPressed: () {
                          logout().then((_) {
                            setState(() {
                              _token = '';
                            });
                          });
                        },
                        child: Text(
                          'Logout',
                          style: theme.textTheme.bodyMedium,
                        ),
                      ),
                    ),
                    const SizedBox(height: 8),
                  ],
                ),
        ),
      ),
    );
  }
}
