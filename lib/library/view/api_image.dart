import 'dart:async';
import 'dart:ui' as ui;

import 'package:abs_wear/library/data/library_api.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/painting.dart';

/// An image fetched with the shared API client, so it reuses its connections.
@immutable
class ApiImage extends ImageProvider<ApiImage> {
  const ApiImage(this.url, this.token);

  final String url;
  final String token;

  @override
  Future<ApiImage> obtainKey(ImageConfiguration configuration) =>
      SynchronousFuture(this);

  @override
  ImageStreamCompleter loadImage(ApiImage key, ImageDecoderCallback decode) =>
      MultiFrameImageStreamCompleter(
        codec: _load(key, decode),
        scale: 1,
        debugLabel: url,
      );

  Future<ui.Codec> _load(ApiImage key, ImageDecoderCallback decode) async {
    try {
      final response = await apiGet(
        url,
        token,
        accept: 'image/webp',
        cover: true,
      );
      if (response.statusCode != 200 || response.bodyBytes.isEmpty) {
        throw ApiException(response.statusCode);
      }
      return await decode(
        await ui.ImmutableBuffer.fromUint8List(response.bodyBytes),
      );
    } on Object {
      // Not cached, so a later build tries again.
      scheduleMicrotask(() => PaintingBinding.instance.imageCache.evict(key));
      rethrow;
    }
  }

  @override
  bool operator ==(Object other) =>
      other is ApiImage && other.url == url && other.token == token;

  @override
  int get hashCode => Object.hash(url, token);

  @override
  String toString() => 'ApiImage($url)';
}
