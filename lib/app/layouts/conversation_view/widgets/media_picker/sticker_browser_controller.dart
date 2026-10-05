import 'dart:async';
import 'package:bluebubbles/app/wrappers/stateful_boilerplate.dart';
import 'package:bluebubbles/app/layouts/conversation_view/widgets/media_picker/sticker_target_preview.dart';
import 'package:bluebubbles/database/models.dart';
import 'package:bluebubbles/services/backend/filesystem/sticker_folder_service.dart';
import 'package:bluebubbles/services/services.dart';
import 'package:flutter/services.dart';
import 'package:get/get.dart';

class StickerBrowserController extends StatefulController {
  static int _nextId = 0;
  late final String tag = '${chat.guid}:sticker-browser:${_nextId++}';
  final Chat chat;
  final StickerFolderService folders;
  final NativeStickerTarget? target;
  final StickerTargetPreview? targetPreview;
  final bool Function()? isTargetCurrent;
  final void Function(StickerFolderEntry)? insertIntoDraft;
  final placement = Rxn<StickerPlacement>();
  final operationSupported = false.obs;
  final submitted = false.obs;
  final entries = <StickerFolderEntry>[].obs;
  final parents = <StickerFolderEntry>[].obs;
  final root = RxnString();
  final folder = RxnString();
  final error = RxnString();
  final capabilityReason = RxnString();
  final selected = Rxn<StickerFolderEntry>();
  final selection = <StickerFolderEntry>[].obs;
  final nativeSticker = true.obs;
  final busy = false.obs;
  final loading = false.obs;
  final supported = false.obs;
  final rowSupported = false.obs;
  bool get canSendNative => target != null
      ? operationSupported.value &&
            targetCurrent &&
            !submitted.value &&
            (target!.operation != NativeStickerOperation.placement ||
                (targetPreview != null && placement.value != null))
      : selection.length > 1
      ? rowSupported.value
      : supported.value;
  bool get targetCurrent =>
      target == null || (HttpSvc.origin == target!.serverIdentity && (isTargetCurrent?.call() ?? true));
  final hasMore = false.obs;
  int _offset = 0;
  int _generation = 0;
  bool _disposed = false;

  StickerBrowserController(this.chat, this.folders, {this.target, this.targetPreview, this.isTargetCurrent, this.insertIntoDraft}) {
    if (target != null &&
        (target!.chatGuid != chat.guid || target!.operation == NativeStickerOperation.removeTapback)) {
      throw ArgumentError('Choose an upload action for this conversation.');
    }
    if (target?.operation == NativeStickerOperation.placement && targetPreview != null) {
      placement.value = StickerPlacement(x: 0.5, y: 0.5, scale: 1, rotation: 0, parentWidth: targetPreview!.size.width);
    }
  }
  bool get active => !_disposed;

  Future<void> initialize() async {
    try {
      final uri = await folders.currentFolder();
      if (!active) return;
      root.value = uri;
      folder.value = uri;
      if (uri != null) await load(reset: true);
    } on PlatformException catch (e) {
      if (active) error.value = e.message;
    } on MissingPluginException {
      if (active) error.value = 'Sticker folder access is unavailable in this app window.';
    }
    if (active) await checkCapability();
  }

  Future<void> checkCapability() async {
    if (!chat.isIMessage) {
      supported.value = false;
      rowSupported.value = false;
      operationSupported.value = false;
      capabilityReason.value = 'Native stickers require an iMessage conversation.';
      return;
    }
    try {
      if (!targetCurrent) throw StateError('The selected message or server changed. Open the message actions again.');
      final capabilities = await HttpSvc.message.stickerCapabilities();
      final value = capabilities['stickerSending'] == true;
      if (!active) return;
      supported.value = value;
      rowSupported.value = capabilities['stickerRows'] == true;
      operationSupported.value = target != null && capabilities[target!.capability] == true;
      capabilityReason.value = target == null
          ? insertIntoDraft != null
              ? capabilities['stickerComposition'] == true ? null : 'You can prepare a draft. The connected helper has not enabled rows or text with stickers.'
              : value
                ? null
                : 'The connected server helper has not enabled native sticker sending.'
          : operationSupported.value
          ? null
          : 'The connected helper has not enabled this sticker action.';
    } catch (_) {
      if (!active) return;
      supported.value = false;
      capabilityReason.value = 'Could not check native sticker support. Reconnect and refresh.';
      rowSupported.value = false;
      operationSupported.value = false;
    }
  }

  Future<void> choose() async {
    busy.value = true;
    try {
      final uri = await folders.chooseFolder();
      if (!active || uri == null) return;
      root.value = uri;
      folder.value = uri;
      parents.clear();
      await load(reset: true);
    } on PlatformException catch (e) {
      if (active) error.value = e.message;
    } on MissingPluginException {
      if (active) error.value = 'Sticker folder access is unavailable in this app window.';
    } finally {
      if (active) busy.value = false;
    }
  }

  Future<void> load({bool reset = false}) async {
    if (folder.value == null || !active) return;
    final generation = ++_generation;
    loading.value = true;
    error.value = null;
    if (reset) {
      entries.clear();
      _offset = 0;
      hasMore.value = false;
      selected.value = null;
      selection.clear();
      nativeSticker.value = true;
    }
    try {
      final page = await folders.list(uri: folder.value!, offset: _offset);
      if (!active || generation != _generation) return;
      entries.addAll(page.entries);
      _offset = page.nextOffset;
      hasMore.value = page.hasMore;
    } on PlatformException catch (e) {
      if (active && generation == _generation) error.value = e.message;
    } on MissingPluginException {
      if (active && generation == _generation) error.value = 'Sticker folder access is unavailable in this app window.';
    } finally {
      if (active && generation == _generation) loading.value = false;
    }
  }

  void select(StickerFolderEntry entry) {
    if (submitted.value) return;
    if (entry.directory) {
      parents.add(entry);
      folder.value = entry.uri;
      unawaited(load(reset: true));
    } else {
      if (insertIntoDraft != null) {
        try { insertIntoDraft!(entry); submitted.value = true; } on StateError catch (failure) { error.value = failure.message.toString(); }
        return;
      }
      if (target != null) {
        selection.assignAll([entry]);
        selected.value = entry;
        nativeSticker.value = true;
        return;
      }
      final index = selection.indexWhere((item) => item.uri == entry.uri);
      if (index >= 0) {
        selection.removeAt(index);
      } else if (selection.length < 10) {
        selection.add(entry);
      } else {
        error.value = 'A sticker row can contain at most 10 stickers.';
      }
      selected.value = selection.lastOrNull;
      nativeSticker.value = true;
    }
  }

  void up() {
    parents.removeLast();
    folder.value = parents.isEmpty ? root.value : parents.last.uri;
    unawaited(load(reset: true));
  }

  Future<void> send() async {
    final entry = selected.value;
    if (!active || entry == null || busy.value || (nativeSticker.value && !canSendNative)) return;
    busy.value = true;
    try {
      if (target != null) {
        if (!targetCurrent) throw StateError('The selected message or server changed.');
        await folders.sendTargeted(
          chat,
          entry,
          target!,
          placement: placement.value,
          canQueue: () => active && targetCurrent,
        );
        if (active) submitted.value = true;
      } else if (selection.length > 1) {
        await folders.sendRow(chat, List.of(selection));
      } else {
        await folders.send(chat, entry, nativeSticker: nativeSticker.value);
      }
      if (active) {
        if (target == null) {
          selected.value = null;
          selection.clear();
        }
      }
    } on PlatformException catch (e) {
      if (active) error.value = e.message;
    } catch (_) {
      if (active) error.value = 'Could not queue the sticker. Check the conversation before sending again.';
    } finally {
      if (active) busy.value = false;
    }
  }

  @override
  void onClose() {
    _disposed = true;
    _generation++;
    super.onClose();
  }
}
