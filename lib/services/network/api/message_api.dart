import 'dart:convert';
import 'package:bluebubbles/database/models.dart';
import 'package:bluebubbles/helpers/types/helpers/reaction_type.dart';
import 'package:bluebubbles/helpers/types/helpers/sticker_helper.dart';
import 'package:bluebubbles/services/network/api/base_api.dart';
import 'package:bluebubbles/services/services.dart';
import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:get/get.dart' hide Response, FormData, MultipartFile;

class MessageApi {
  final BaseApi _svc;

  MessageApi(this._svc);

  /// Get the number of messages in the server iMessage DB
  Future<Response> getCount({
    bool updated = false,
    bool onlyMe = false,
    DateTime? after,
    DateTime? before,
    CancelToken? cancelToken,
  }) async {
    // we don't have a query that supports providing updated and onlyMe
    assert(updated != true && onlyMe != true);
    Map<String, dynamic> params = {};
    if (after != null) params['after'] = after.millisecondsSinceEpoch;
    if (before != null) params['before'] = before.millisecondsSinceEpoch;
    return _svc.runApiGuarded(() async {
      final response = await _svc.dio.get(
        "${_svc.apiRoot}/message/count${updated
            ? "/updated"
            : onlyMe
            ? "/me"
            : ""}",
        queryParameters: _svc.buildQueryParams(params),
        cancelToken: cancelToken,
      );
      return _svc.returnSuccessOrError(response);
    });
  }

  /// Query the messages DB. Use [withQuery] to specify what you would like in
  /// the response or how to query the DB.
  ///
  /// [withQuery] options: `"chats"` / `"chat"`, `"attachment"` / `"attachments"`,
  /// `"handle"`, `"chats.participants"` / `"chat.participants"`,
  /// `"attachment.metadata"`, `"attributedBody"`
  Future<Response> query({
    List<String> withQuery = const [],
    List<dynamic> where = const [],
    String sort = "DESC",
    int? before,
    int? after,
    String? chatGuid,
    int offset = 0,
    int limit = 100,
    bool convertAttachments = true,
    CancelToken? cancelToken,
  }) async {
    return _svc.runApiGuarded(() async {
      final response = await _svc.dio.post(
        "${_svc.apiRoot}/message/query",
        queryParameters: _svc.buildQueryParams(),
        data: {
          "with": withQuery,
          "where": where,
          "sort": sort,
          "before": before,
          "after": after,
          "chatGuid": chatGuid,
          "offset": offset,
          "limit": limit,
          "convertAttachments": convertAttachments,
        },
        cancelToken: cancelToken,
      );
      return _svc.returnSuccessOrError(response);
    });
  }

  /// Get a single message by [guid]. Use [withQuery] to specify what you would
  /// like in the response or how to query the DB.
  ///
  /// [withQuery] options: `"chats"` / `"chat"`, `"attachment"` / `"attachments"`,
  /// `"chats.participants"` / `"chat.participants"`, `"attributedBody"`
  /// (set as one string, comma separated, no spaces)
  Future<Response> fetchOne(String guid, {String withQuery = "", CancelToken? cancelToken}) async {
    return _svc.runApiGuarded(() async {
      final response = await _svc.dio.get(
        "${_svc.apiRoot}/message/$guid",
        queryParameters: _svc.buildQueryParams({"with": withQuery}),
        cancelToken: cancelToken,
      );
      return _svc.returnSuccessOrError(response);
    });
  }

  /// Get embedded media for a single digital touch or handwritten message by [guid]
  Future<Response> downloadEmbeddedMedia(
    String guid, {
    void Function(int, int)? onReceiveProgress,
    CancelToken? cancelToken,
  }) async {
    return _svc.runApiGuarded(() async {
      final response = await _svc.dio.get(
        "${_svc.apiRoot}/message/$guid/embedded-media",
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

  /// Send a message. [chatGuid] specifies the chat, [tempGuid] specifies a
  /// temporary guid to avoid duplicate messages being sent, [message] is the
  /// body of the message. Optionally provide [method] to send via private API,
  /// [effectId] to send with an effect, or [subject] to send with a subject.
  Future<Response> sendText(
    String chatGuid,
    String tempGuid,
    String message, {
    String? method,
    String? effectId,
    String? subject,
    String? selectedMessageGuid,
    int? partIndex,
    bool? ddScan,
    CancelToken? cancelToken,
  }) async {
    return _svc.runApiGuarded(() async {
      Map<String, dynamic> data = {
        "chatGuid": chatGuid,
        "tempGuid": tempGuid,
        "message": message.isEmpty && (subject?.isNotEmpty ?? false) ? " " : message,
        "method": method,
      };

      data.addAllIf(SettingsSvc.settings.enablePrivateAPI.value && SettingsSvc.settings.privateAPISend.value, {
        "effectId": effectId,
        "subject": subject,
        "selectedMessageGuid": selectedMessageGuid,
        "partIndex": partIndex,
      });

      if (SettingsSvc.settings.enablePrivateAPI.value &&
          SettingsSvc.settings.privateAPISend.value &&
          SettingsSvc.serverDetails.isMinVentura) {
        data["ddScan"] = ddScan;
      }

      final response = await _svc.dio.post(
        "${_svc.apiRoot}/message/text",
        queryParameters: _svc.buildQueryParams(),
        data: data,
        cancelToken: cancelToken,
      );
      return _svc.returnSuccessOrError(response);
    });
  }

  /// Send an attachment. [chatGuid] specifies the chat, [tempGuid] specifies a
  /// temporary guid to avoid duplicate messages being sent, [file] is the
  /// body of the message.
  Future<Response> sendAttachment(
    String chatGuid,
    String tempGuid,
    PlatformFile file, {
    void Function(int, int)? onSendProgress,
    String? method,
    String? effectId,
    String? subject,
    String? selectedMessageGuid,
    int? partIndex,
    bool? isAudioMessage,
    CancelToken? cancelToken,
  }) async {
    return _svc.runApiGuarded(() async {
      final fileName = file.name;
      final formData = FormData.fromMap({
        "attachment": kIsWeb
            ? MultipartFile.fromBytes(file.bytes!, filename: fileName)
            : await MultipartFile.fromFile(file.path!, filename: fileName),
        "chatGuid": chatGuid,
        "tempGuid": tempGuid,
        "name": fileName,
        "method": method,
      });

      if (SettingsSvc.settings.enablePrivateAPI.value && SettingsSvc.settings.privateAPIAttachmentSend.value) {
        Map<String, dynamic> papiData = {
          "effectId": effectId,
          "subject": subject,
          "selectedMessageGuid": selectedMessageGuid,
          "partIndex": partIndex,
          "isAudioMessage": isAudioMessage,
        };

        papiData.removeWhere((key, value) => value == null);
        formData.fields.addAll(papiData.entries.map((entry) => MapEntry(entry.key, entry.value.toString())));
      }

      final response = await _svc.dio.post(
        "${_svc.apiRoot}/message/attachment",
        queryParameters: _svc.buildQueryParams(),
        cancelToken: cancelToken,
        data: formData,
        onSendProgress: onSendProgress,
        options: Options(
          sendTimeout: _svc.dio.options.sendTimeout! * 12,
          receiveTimeout: _svc.dio.options.receiveTimeout! * 12,
          headers: _svc.headers,
        ),
      );
      return _svc.returnSuccessOrError(response);
    });
  }

  /// Checks the connected helper instead of trusting the isolate's cached details.
  Future<Map<String, bool>> stickerCapabilities({CancelToken? cancelToken}) async {
    final info = await _svc.runApiGuarded(() async {
      final response = await _svc.dio.get(
        '${_svc.apiRoot}/server/info',
        queryParameters: _svc.buildQueryParams(),
        cancelToken: cancelToken,
      );
      return _svc.returnSuccessOrError(response);
    });
    final data = info.data is Map ? info.data['data'] : null;
    final capabilities = data is Map ? data['privateApiCapabilities'] : null;
    return {
      for (final key in ['stickerSending', 'stickerRows', 'stickerPlacement', 'stickerReactions', 'stickerComposition'])
        key: capabilities is Map && capabilities[key] == true,
    };
  }

  Future<bool> supportsStickerSending({CancelToken? cancelToken}) async =>
      (await stickerCapabilities(cancelToken: cancelToken))['stickerSending'] == true;

  Future<Response> sendTargetedSticker(NativeStickerTarget target, String tempGuid,
      {PlatformFile? file, StickerPlacement? placement, String? stickerLabel, CancelToken? cancelToken}) async {
    if (_svc.origin != target.serverIdentity) throw StateError('The server changed. Choose the target message again.');
    final removal = target.operation == NativeStickerOperation.removeTapback;
    if (removal != (file == null) || (target.operation == NativeStickerOperation.placement) != (placement != null)) {
      throw ArgumentError('The sticker operation has inconsistent asset or placement data.');
    }
    return _svc.runApiGuarded(() async {
      final capabilities = await stickerCapabilities(cancelToken: cancelToken);
      if (capabilities[target.capability] != true) {
        throw UnsupportedError('The connected helper has not enabled this sticker operation.');
      }
      if (_svc.origin != target.serverIdentity) throw StateError('The server changed. Choose the target message again.');
      final fields = <String, dynamic>{'chatGuid': target.chatGuid, 'tempGuid': tempGuid,
        'selectedMessageGuid': target.messageGuid, 'partIndex': removal ? target.partIndex : target.partIndex.toString(),
        if (removal) 'reactionGuid': target.reactionGuid};
      final Object data;
      if (removal) {
        data = fields;
      } else {
        data = FormData.fromMap({...fields, 'name': file!.name, 'stickerLabel': ?stickerLabel,
          if (placement != null) 'placement': jsonEncode(placement.toMap()),
          'attachment': await MultipartFile.fromFile(file.path!, filename: file.name)});
      }
      if (_svc.origin != target.serverIdentity) throw StateError('The server changed. Choose the target message again.');
      final response = await _svc.dio.post('${_svc.apiRoot}/message/${target.endpoint}',
        queryParameters: _svc.buildQueryParams(), options: Options(headers: _svc.headers), data: data, cancelToken: cancelToken);
      return _svc.returnSuccessOrError(response);
    }, retryOn502: false);
  }

  /// Uploads an ordered native row as one message, with one stable temp GUID.
  Future<Response> sendStickerRow(
    String chatGuid,
    String tempGuid,
    List<PlatformFile> files, {
    List<String?>? stickerLabels,
    String? text,
    String? expectedOrigin,
    CancelToken? cancelToken,
  }) async {
    if (text != null) {
      StickerHelper.validateCompositionText(text, files.length);
      if (expectedOrigin == null || expectedOrigin.isEmpty) {
        throw ArgumentError('The sticker draft requires its server.');
      }
      if (files.any((file) => file.path == null || file.size < 1 || file.size > 500 * 1024) ||
          files.fold<int>(0, (bytes, file) => bytes + file.size) > 5 * 1024 * 1024) {
        throw ArgumentError('The sticker draft exceeds its upload limits.');
      }
    } else if (files.length < 2 || files.length > 10) {
      throw ArgumentError('A sticker row requires 2 to 10 stickers.');
    }
    if (stickerLabels != null && stickerLabels.length != files.length) {
      throw ArgumentError('Each sticker label must correspond to its file.');
    }
    final origin = expectedOrigin ?? _svc.origin;
    if (_svc.origin != origin) throw StateError('The server changed. Open the original chat to send this draft.');
    final descriptors = jsonEncode([
      for (var i = 0; i < files.length; i++) {'name': files[i].name, 'stickerLabel': ?stickerLabels?[i]},
    ]);
    if (text != null && utf8.encode('$chatGuid$tempGuid$descriptors$text').length > 8192) {
      throw ArgumentError('The sticker draft is too large. Shorten the text or filenames.');
    }
    return _svc.runApiGuarded(() async {
      final capability = text == null ? 'stickerRows' : 'stickerComposition';
      if ((await stickerCapabilities(cancelToken: cancelToken))[capability] != true) {
        throw UnsupportedError(
          text == null
              ? 'The connected server helper has not enabled native sticker rows.'
              : 'The connected server helper has not enabled text with stickers. Your draft is still here.',
        );
      }
      if (_svc.origin != origin) throw StateError('The server changed. Choose the sticker row again.');
      final form = FormData.fromMap({
        'chatGuid': chatGuid,
        'tempGuid': tempGuid,
        'stickers': descriptors,
        'text': ?text,
        for (var i = 0; i < files.length; i++)
          'attachment$i': await MultipartFile.fromFile(files[i].path!, filename: files[i].name),
      });
      if (_svc.origin != origin) throw StateError('The server changed. Choose the sticker row again.');
      final response = await _svc.dio.post('${_svc.apiRoot}/message/send-sticker-row',
          queryParameters: _svc.buildQueryParams(), data: form, cancelToken: cancelToken,
          options: Options(headers: _svc.headers));
      if (text != null && _svc.origin != origin) {
        throw StateError('The server changed before sticker confirmation. Check Messages before sending again.');
      }
      return _svc.returnSuccessOrError(response);
    }, retryOn502: false);
  }

  /// Sends original sticker bytes once. An ambiguous response must not resend.
  Future<Response> sendSticker(
    String chatGuid,
    String tempGuid,
    PlatformFile file, {
    String? stickerLabel,
    String? expectedOrigin,
    CancelToken? cancelToken,
  }) async {
    final origin = expectedOrigin ?? _svc.origin;
    if (_svc.origin != origin) throw StateError('The server changed. Open the original chat to send this draft.');
    return _svc.runApiGuarded(() async {
      if (!await supportsStickerSending(cancelToken: cancelToken)) {
        throw UnsupportedError('The connected server helper has not enabled native sticker sending.');
      }
      if (_svc.origin != origin) throw StateError('The server changed. Choose the sticker again.');
      final form = FormData.fromMap({
        'attachment': await MultipartFile.fromFile(file.path!, filename: file.name),
        'chatGuid': chatGuid,
        'tempGuid': tempGuid,
        'name': file.name,
        'stickerLabel': ?stickerLabel,
      });
      if (_svc.origin != origin) throw StateError('The server changed. Choose the sticker again.');
      final response = await _svc.dio.post(
        '${_svc.apiRoot}/message/send-sticker',
        queryParameters: _svc.buildQueryParams(),
        data: form,
        cancelToken: cancelToken,
        options: Options(headers: _svc.headers),
      );
      if (expectedOrigin != null && _svc.origin != origin) {
        throw StateError('The server changed before sticker confirmation. Check Messages before sending again.');
      }
      return _svc.returnSuccessOrError(response);
    }, retryOn502: false);
  }

  /// Send a multipart message. [chatGuid] specifies the chat, [tempGuid] specifies a
  /// temporary guid to avoid duplicate messages being sent, [parts] is the list
  /// of message parts.
  Future<Response> sendMultipart(
    String chatGuid,
    String tempGuid,
    List<Map<String, dynamic>> parts, {
    String? effectId,
    String? subject,
    String? selectedMessageGuid,
    int? partIndex,
    bool? ddScan,
    CancelToken? cancelToken,
  }) async {
    return _svc.runApiGuarded(() async {
      Map<String, dynamic> data = {
        "chatGuid": chatGuid,
        "tempGuid": tempGuid,
        "effectId": effectId,
        "subject": subject,
        "selectedMessageGuid": selectedMessageGuid,
        "partIndex": partIndex,
        "parts": parts,
      };

      if (SettingsSvc.serverDetails.isMinVentura) {
        data["ddScan"] = ddScan;
      }

      final response = await _svc.dio.post(
        "${_svc.apiRoot}/message/multipart",
        queryParameters: _svc.buildQueryParams(),
        data: data,
        cancelToken: cancelToken,
      );
      return _svc.returnSuccessOrError(response);
    });
  }

  /// Send a reaction. [chatGuid] specifies the chat, [selectedMessageText]
  /// specifies the text of the message being reacted on, [selectedMessageGuid]
  /// is the guid of the message, and [reaction] is the reaction type.
  Future<Response> sendTapback(
    String chatGuid,
    String selectedMessageText,
    String selectedMessageGuid,
    String reaction, {
    int? partIndex,
    CancelToken? cancelToken,
  }) async {
    if (!ReactionTypes.isClassic(reaction) && !ReactionTypes.isCustom(reaction)) {
      throw ArgumentError.value(reaction, 'reaction', 'Expected a classic tapback or single emoji');
    }
    return _svc.runApiGuarded(() async {
      if (ReactionTypes.isCustom(reaction)) {
        // Sends run inside GlobalIsolate, whose bootstrap cache deliberately
        // has no negotiated capability. Check the currently connected helper
        // here instead of relying on a main-isolate or version-only cache.
        final info = await _svc.dio.get(
          '${_svc.apiRoot}/server/info',
          queryParameters: _svc.buildQueryParams(),
          cancelToken: cancelToken,
        );
        await _svc.returnSuccessOrError(info);
        final data = info.data is Map ? info.data['data'] : null;
        final capabilities = data is Map ? data['privateApiCapabilities'] : null;
        if (capabilities is! Map || capabilities['customEmojiReactions'] != true) {
          throw UnsupportedError('This server has not enabled custom emoji reactions');
        }
      }
      final response = await _svc.dio.post(
        "${_svc.apiRoot}/message/react",
        queryParameters: _svc.buildQueryParams(),
        data: {
          "chatGuid": chatGuid,
          "selectedMessageText": selectedMessageText,
          "selectedMessageGuid": selectedMessageGuid,
          "reaction": reaction,
          "partIndex": partIndex,
        },
        cancelToken: cancelToken,
      );
      return _svc.returnSuccessOrError(response);
    });
  }

  /// Unsend a message part
  Future<Response> unsend(String selectedMessageGuid, {int? partIndex, CancelToken? cancelToken}) async {
    return _svc.runApiGuarded(() async {
      final response = await _svc.dio.post(
        "${_svc.apiRoot}/message/$selectedMessageGuid/unsend",
        queryParameters: _svc.buildQueryParams(),
        data: {"partIndex": partIndex ?? 0},
        cancelToken: cancelToken,
      );
      return _svc.returnSuccessOrError(response);
    });
  }

  /// Edit a sent message
  Future<Response> edit(
    String selectedMessageGuid,
    String edit,
    String backwardsCompatText, {
    int? partIndex,
    CancelToken? cancelToken,
  }) async {
    return _svc.runApiGuarded(() async {
      final response = await _svc.dio.post(
        "${_svc.apiRoot}/message/$selectedMessageGuid/edit",
        queryParameters: _svc.buildQueryParams(),
        data: {
          "editedMessage": edit,
          "backwardsCompatibilityMessage": backwardsCompatText,
          "partIndex": partIndex ?? 0,
        },
        cancelToken: cancelToken,
      );
      return _svc.returnSuccessOrError(response);
    });
  }

  /// Notify (ping) a message
  Future<Response> notify(String selectedMessageGuid, {CancelToken? cancelToken}) async {
    return _svc.runApiGuarded(() async {
      final response = await _svc.dio.post(
        "${_svc.apiRoot}/message/$selectedMessageGuid/notify",
        queryParameters: _svc.buildQueryParams(),
        cancelToken: cancelToken,
      );
      return _svc.returnSuccessOrError(response);
    });
  }

  /// Get scheduled messages from server
  Future<Response> getScheduled({CancelToken? cancelToken}) async {
    return _svc.runApiGuarded(() async {
      final response = await _svc.dio.get(
        "${_svc.apiRoot}/message/schedule",
        queryParameters: _svc.buildQueryParams(),
        cancelToken: cancelToken,
      );
      return _svc.returnSuccessOrError(response);
    });
  }

  /// Create a scheduled message
  Future<Response> createScheduled(
    String chatGuid,
    String message,
    DateTime date,
    Map<String, dynamic> schedule, {
    CancelToken? cancelToken,
  }) async {
    return _svc.runApiGuarded(() async {
      final response = await _svc.dio.post(
        "${_svc.apiRoot}/message/schedule",
        queryParameters: _svc.buildQueryParams(),
        cancelToken: cancelToken,
        data: {
          "type": "send-message",
          "payload": {
            "chatGuid": chatGuid,
            "message": message,
            "method": SettingsSvc.settings.privateAPISend.value ? 'private-api' : "apple-script",
          },
          "scheduledFor": date.millisecondsSinceEpoch,
          "schedule": schedule,
        },
      );
      return _svc.returnSuccessOrError(response);
    });
  }

  /// Update a scheduled message
  Future<Response> updateScheduled(
    int id,
    String chatGuid,
    String message,
    DateTime date,
    Map<String, dynamic> schedule, {
    CancelToken? cancelToken,
  }) async {
    return _svc.runApiGuarded(() async {
      final response = await _svc.dio.put(
        "${_svc.apiRoot}/message/schedule/$id",
        queryParameters: _svc.buildQueryParams(),
        cancelToken: cancelToken,
        data: {
          "type": "send-message",
          "payload": {"chatGuid": chatGuid, "message": message, "method": "apple-script"},
          "scheduledFor": date.millisecondsSinceEpoch,
          "schedule": schedule,
        },
      );
      return _svc.returnSuccessOrError(response);
    });
  }

  /// Delete a scheduled message
  Future<Response> deleteScheduled(int id, {CancelToken? cancelToken}) async {
    return _svc.runApiGuarded(() async {
      final response = await _svc.dio.delete(
        "${_svc.apiRoot}/message/schedule/$id",
        queryParameters: _svc.buildQueryParams(),
        cancelToken: cancelToken,
      );
      return _svc.returnSuccessOrError(response);
    });
  }
}
