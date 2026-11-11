import 'package:abs_wear/library/data/library_api.dart';
import 'package:abs_wear/library/view/api_image.dart';
import 'package:flutter/material.dart';

/// A small cover thumbnail. Decoded at display size, so hundreds of
/// covers in a long list don't exhaust the watch's memory.
class BookCover extends StatelessWidget {
  const BookCover({
    required this.serverUrl,
    required this.token,
    required this.bookId,
    required this.size,
    super.key,
  });

  final String serverUrl;
  final String token;
  final String bookId;
  final double size;

  @override
  Widget build(BuildContext context) {
    final pixels = (size * MediaQuery.devicePixelRatioOf(context)).round();
    return ClipRRect(
      borderRadius: BorderRadius.circular(4),
      child: Image(
        image: ResizeImage(
          ApiImage('$serverUrl/api/items/$bookId/cover?width=$pixels', token),
          width: pixels,
        ),
        width: size,
        height: size,
        fit: BoxFit.cover,
        // Decorative: the title is read out next to every cover.
        excludeFromSemantics: true,
        // Books without cover art return 404; show a placeholder
        // instead of Flutter's oversized error widget.
        errorBuilder: (_, _, _) => SizedBox.square(
          dimension: size,
          child: Icon(Icons.book_rounded, size: size * 0.6),
        ),
      ),
    );
  }
}

/// One row in the library browser: cover, title, author.
class BookTile extends StatelessWidget {
  const BookTile({
    required this.book,
    required this.serverUrl,
    required this.token,
    required this.onTap,
    super.key,
  });

  static const double height = 60;

  final ShelfBook book;
  final String serverUrl;
  final String token;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return InkWell(
      onTap: onTap,
      child: SizedBox(
        height: height,
        child: Row(
          children: [
            BookCover(
              serverUrl: serverUrl,
              token: token,
              bookId: book.id,
              size: 44,
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    book.title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.bodySmall,
                  ),
                  Text(
                    book.author,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.labelSmall,
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
