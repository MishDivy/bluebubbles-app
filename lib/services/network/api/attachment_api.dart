import 'dart:typed_data';
import 'dart:async';
import 'package:bluebubbles/services/network/api/base_api.dart';
import 'package:dio/dio.dart';
import 'package:universal_io/io.dart';

class AttachmentApi {
  final BaseApi _svc;
  final Duration _previewDeadline;

  AttachmentApi(this._svc, {Duration previewDeadline = const Duration(seconds: 60)})
    : _previewDeadline = previewDeadline {
    if (previewDeadline <= Duration.zero || previewDeadline > const Duration(seconds: 60)) {
      throw ArgumentError('Sticker preview deadlines must be within 60 seconds.');
    }
  }

  static const maxStickerPreviewBytes = 16 * 1024 * 1024;

  /// A display-only PNG/APNG. The original attachment download is separate.
  Future<Response> stickerPreview(String guid, {CancelToken? cancelToken, String? expectedOrigin}) async {
    final origin = expectedOrigin ?? _svc.origin;
    if (_svc.origin != origin) throw StateError('The server changed before loading the sticker preview.');
    final token = cancelToken ?? CancelToken();
    final deadline = Timer(_previewDeadline, () => token.cancel('Sticker preview timed out'));
    try {
      return await _svc.runApiGuarded(() async {
        if (_svc.origin != origin) throw StateError('The server changed before loading the sticker preview.');
        final response = await _svc.dio.get(
          '${_svc.apiRoot}/attachment/${Uri.encodeComponent(guid)}/sticker-preview',
          queryParameters: _svc.buildQueryParams(),
          cancelToken: token,
          options: Options(
            responseType: ResponseType.stream,
            headers: _svc.headers,
            validateStatus: (_) => true,
            receiveTimeout: const Duration(seconds: 60),
          ),
        );
        final body = response.data;
        var consumed = false;
        var succeeded = false;
        try {
          await _svc.returnSuccessOrError(response);
          final length = int.tryParse(response.headers.value('content-length') ?? '');
          if (response.headers.value('content-type')?.split(';').first.trim() != 'image/png' ||
              (length != null && length > maxStickerPreviewBytes)) {
            throw StateError('The server returned an unsupported sticker preview.');
          }
          if (body is! ResponseBody) throw StateError('The sticker preview has no image data.');
          final bytes = BytesBuilder();
          consumed = true;
          await for (final chunk in body.stream) {
            if (bytes.length + chunk.length > maxStickerPreviewBytes) {
              throw StateError('The sticker preview exceeds the size limit.');
            }
            bytes.add(chunk);
          }
          final data = bytes.takeBytes().asUnmodifiableView();
          validateStickerPreview(data, response.headers);
          if (_svc.origin != origin) throw StateError('The server changed while loading the sticker preview.');
          succeeded = true;
          return Response(
            requestOptions: response.requestOptions,
            statusCode: response.statusCode,
            headers: response.headers,
            data: data,
          );
        } finally {
          if (!succeeded) token.cancel('Sticker preview request failed');
          if (!consumed && body is ResponseBody) {
            // Also release rejected responses whose stream was never consumed.
            await body.stream.listen((_) {}).cancel();
          }
        }
      }, retryOn502: false);
    } finally {
      deadline.cancel();
    }
  }

  /// Check canvas/frame bounds before handing compressed data to an image codec.
  static void validateStickerPreview(Uint8List bytes, Headers headers) {
    Never invalid() => throw StateError('The server returned an invalid sticker preview.');
    const signature = [137, 80, 78, 71, 13, 10, 26, 10];
    if (bytes.length < 45 || bytes.length > maxStickerPreviewBytes) invalid();
    for (var i = 0; i < signature.length; i++) {
      if (bytes[i] != signature[i]) invalid();
    }
    final data = ByteData.sublistView(bytes);
    int number(int offset) => data.getUint32(offset);
    if (number(8) != 13 || String.fromCharCodes(bytes.sublist(12, 16)) != 'IHDR') invalid();
    final width = number(16), height = number(20);
    if (width < 1 || height < 1 || width > 618 || height > 618) invalid();
    var frames = 1, frameChunks = 0, animated = false, ended = false;
    for (var offset = 8; offset + 12 <= bytes.length;) {
      final length = number(offset);
      if (length > bytes.length - offset - 12) invalid();
      final type = String.fromCharCodes(bytes.sublist(offset + 4, offset + 8));
      if (type == 'acTL') {
        if (animated || length != 8) invalid();
        animated = true;
        frames = number(offset + 8);
        if (frames < 1 || frames > 100) invalid();
      } else if (type == 'fcTL') {
        if (!animated || length != 26) invalid();
        frameChunks++;
        final frameWidth = number(offset + 12), frameHeight = number(offset + 16);
        if (frameWidth < 1 ||
            frameHeight < 1 ||
            frameWidth + number(offset + 20) > width ||
            frameHeight + number(offset + 24) > height) {
          invalid();
        }
      } else if (type == 'IEND') {
        if (length != 0 || offset + 12 != bytes.length) invalid();
        ended = true;
      }
      offset += length + 12;
    }
    if (!ended || (animated && frameChunks != frames) || width * height * frames > 25000000) {
      invalid();
    }
    final format = headers.value('x-bb-sticker-preview-format');
    if (format != (animated ? 'apng' : 'png') ||
        int.tryParse(headers.value('x-bb-sticker-preview-frames') ?? '') != frames ||
        int.tryParse(headers.value('x-bb-sticker-preview-width') ?? '') != width ||
        int.tryParse(headers.value('x-bb-sticker-preview-height') ?? '') != height) {
      invalid();
    }
  }

  /// Get the attachment data for the specified [guid]
  Future<Response> fetch(String guid, {CancelToken? cancelToken}) async {
    return _svc.runApiGuarded(() async {
      final response = await _svc.dio.get(
        "${_svc.apiRoot}/attachment/$guid",
        queryParameters: _svc.buildQueryParams(),
        cancelToken: cancelToken,
      );
      return _svc.returnSuccessOrError(response);
    });
  }

  /// Download the attachment data for the specified [guid].
  /// If [savePath] is provided, downloads directly to that file path (more efficient, avoids loading into memory).
  /// Otherwise returns bytes in response data (legacy behavior for web).
  Future<Response> download(
    String guid, {
    void Function(int, int)? onReceiveProgress,
    bool original = false,
    CancelToken? cancelToken,
    String? savePath,
  }) async {
    return _svc.runApiGuarded(() async {
      final response = await _svc.dio.get(
        "${_svc.apiRoot}/attachment/$guid/download",
        queryParameters: _svc.buildQueryParams({"original": original}),
        options: Options(
          responseType: savePath != null ? ResponseType.stream : ResponseType.bytes,
          receiveTimeout: _svc.dio.options.receiveTimeout! * 12,
          headers: _svc.headers,
        ),
        cancelToken: cancelToken,
        onReceiveProgress: onReceiveProgress,
      );

      // If savePath provided, write stream directly to file
      if (savePath != null && response.data != null) {
        final file = File(savePath);
        await file.parent.create(recursive: true);

        final raf = await file.open(mode: FileMode.write);
        try {
          await for (final chunk in response.data.stream) {
            await raf.writeFrom(chunk);
          }
        } finally {
          await raf.close();
        }

        // Return response with file info instead of bytes
        return Response(
          requestOptions: response.requestOptions,
          statusCode: response.statusCode,
          statusMessage: response.statusMessage,
          headers: response.headers,
          extra: response.extra,
        );
      }

      return _svc.returnSuccessOrError(response);
    });
  }

  /// Get the live photo data for the specified [guid]
  Future<Response> downloadLivePhoto(
    String guid, {
    void Function(int, int)? onReceiveProgress,
    CancelToken? cancelToken,
  }) async {
    return _svc.runApiGuarded(() async {
      final response = await _svc.dio.get(
        "${_svc.apiRoot}/attachment/$guid/live",
        queryParameters: _svc.buildQueryParams(),
        options: Options(
          responseType: ResponseType.bytes,
          receiveTimeout: _svc.dio.options.receiveTimeout! * 12,
          headers: _svc.headers,
        ),
        cancelToken: cancelToken,
        onReceiveProgress: onReceiveProgress,
      );
      return _svc.returnSuccessOrError(response);
    });
  }

  /// Get the attachment blurhash for the specified [guid]
  Future<Response> downloadBlurhash(
    String guid, {
    void Function(int, int)? onReceiveProgress,
    CancelToken? cancelToken,
  }) async {
    return _svc.runApiGuarded(() async {
      final response = await _svc.dio.get(
        "${_svc.apiRoot}/attachment/$guid/blurhash",
        queryParameters: _svc.buildQueryParams(),
        options: Options(
          responseType: ResponseType.bytes,
          receiveTimeout: _svc.dio.options.receiveTimeout! * 12,
          headers: _svc.headers,
        ),
        cancelToken: cancelToken,
        onReceiveProgress: onReceiveProgress,
      );
      return _svc.returnSuccessOrError(response);
    });
  }

  /// Get the number of attachments in the server iMessage DB
  Future<Response> getCount({CancelToken? cancelToken}) async {
    return _svc.runApiGuarded(() async {
      final response = await _svc.dio.get(
        "${_svc.apiRoot}/attachment/count",
        queryParameters: _svc.buildQueryParams(),
        cancelToken: cancelToken,
      );
      return _svc.returnSuccessOrError(response);
    });
  }
}
