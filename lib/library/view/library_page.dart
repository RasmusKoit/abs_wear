// ignore_for_file: avoid_dynamic_calls

import 'dart:convert';

import 'package:audiobookshelfwear/l10n/l10n.dart';
import 'package:audiobookshelfwear/player/player.dart';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;

class LibraryPage extends StatefulWidget {
  const LibraryPage({
    required this.token,
    required this.serverUrl,
    required this.libraryId,
    required this.user,
    super.key,
  });
  final String token;
  final String serverUrl;
  final String libraryId;
  final String user;

  @override
  State<LibraryPage> createState() => _LibraryPageState();
}

class _LibraryPageState extends State<LibraryPage> {
  Future<List<dynamic>> getContinueListening(
    String token,
    String serverUrl,
  ) async {
    final response = await http.get(
      Uri.parse(
        '$serverUrl/api/libraries/${widget.libraryId}/personalized?limit=5',
      ),
      headers: <String, String>{
        'Authorization': 'Bearer $token',
      },
    );
    if (response.statusCode == 200) {
      final data = jsonDecode(response.body);
      return data.firstWhere(
        // ignore: inference_failure_on_untyped_parameter
        (item) => item['id'] == 'continue-listening',
      )['entities'] as List<dynamic>;
    } else {
      throw Exception('Failed to load listening sessions');
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    return Scaffold(
      appBar: PreferredSize(
        preferredSize: const Size.fromHeight(40),
        child: AppBar(
          centerTitle: true,
          title: Text(
            l10n.library,
            style: theme.textTheme.bodyLarge,
          ),
          automaticallyImplyLeading: false,
        ),
      ),
      body: SingleChildScrollView(
        child: Padding(
          padding: const EdgeInsets.all(8),
          child: Column(
            children: [
              Text(l10n.continueListening),
              FutureBuilder<List<dynamic>>(
                future: getContinueListening(
                  widget.token,
                  widget.serverUrl,
                ),
                builder: (context, snapshot) {
                  if (snapshot.connectionState == ConnectionState.done) {
                    if (snapshot.hasData) {
                      return Column(
                        children: snapshot.data!.map((item) {
                          final coverUrl =
                              "${widget.serverUrl}/api/items/${item['id']}/cover?token=${widget.token}";
                          return Card(
                            child: ListTile(
                              title: Text(
                                "${item['media']['metadata']['title']}",
                                style: theme.textTheme.bodySmall,
                              ),
                              subtitle: Text(
                                "${item['media']['metadata']['authorName']}",
                                style: theme.textTheme.labelSmall,
                              ),
                              trailing: Image.network(
                                coverUrl,
                                width: 50,
                                height: 50,
                              ),
                              onTap: () {
                                Navigator.push(
                                  context,
                                  MaterialPageRoute<dynamic>(
                                    builder: (context) => PlayerView(
                                      token: widget.token,
                                      serverUrl: widget.serverUrl,
                                      libraryItemId: item['id'] as String,
                                      user: widget.user,
                                    ),
                                  ),
                                );
                              },
                            ),
                          );
                        }).toList(),
                      );
                    } else if (snapshot.hasError) {
                      return Text(l10n.errorLoadingData);
                    }
                  }
                  return const Center(child: CircularProgressIndicator());
                },
              ),
              Card(
                child: ListTile(
                  title: Text(
                    l10n.refresh,
                    style: theme.textTheme.bodySmall,
                  ),
                  trailing: const Icon(Icons.refresh),
                  onTap: () {
                    setState(() {
                      getContinueListening(
                        widget.token,
                        widget.serverUrl,
                      );
                    });
                  },
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
