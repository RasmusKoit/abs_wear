import 'package:abs_wear/app/view/crown_scrollbar.dart';
import 'package:abs_wear/l10n/l10n.dart';
import 'package:abs_wear/library/data/library_api.dart';
import 'package:flutter/material.dart';

/// Lets the user switch between the server's book and podcast libraries.
/// Pops with the picked library's id.
class LibrariesPage extends StatefulWidget {
  const LibrariesPage({
    required this.libraries,
    required this.currentId,
    super.key,
  });

  final List<LibraryInfo> libraries;
  final String currentId;

  @override
  State<LibrariesPage> createState() => _LibrariesPageState();
}

class _LibrariesPageState extends State<LibrariesPage> {
  final _scrollController = ScrollController();

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return CrownScrollbar(
      controller: _scrollController,
      child: Scaffold(
        appBar: PreferredSize(
          preferredSize: const Size.fromHeight(40),
          child: AppBar(
            centerTitle: true,
            automaticallyImplyLeading: false,
            title: Text(
              context.l10n.libraries,
              style: theme.textTheme.bodyLarge,
            ),
          ),
        ),
        body: ListView(
          controller: _scrollController,
          padding: const EdgeInsets.fromLTRB(24, 4, 24, 48),
          children: [
            for (final library in widget.libraries)
              Card(
                child: ListTile(
                  leading: Icon(
                    library.isPodcast
                        ? Icons.podcasts_rounded
                        : Icons.menu_book_rounded,
                  ),
                  title: Text(library.name, style: theme.textTheme.bodySmall),
                  trailing: library.id == widget.currentId
                      ? const Icon(Icons.check_rounded)
                      : null,
                  onTap: () => Navigator.of(context).pop(library.id),
                ),
              ),
          ],
        ),
      ),
    );
  }
}
