import 'dart:async';

import 'package:audio_waveforms/audio_waveforms.dart';
import 'package:bluebubbles/app/components/custom_text_editing_controllers.dart';
import 'package:bluebubbles/app/layouts/conversation_view/widgets/text_field/sticker_composition_controller.dart';
import 'package:bluebubbles/app/wrappers/stateful_boilerplate.dart';
import 'package:bluebubbles/database/models.dart';
import 'package:bluebubbles/services/backend/interfaces/prefs_interface.dart';
import 'package:bluebubbles/services/backend/filesystem/sticker_folder_service.dart';
import 'package:bluebubbles/services/services.dart';
import 'package:flutter/material.dart';
import 'package:flutter_keyboard_visibility/flutter_keyboard_visibility.dart';
import 'package:get/get.dart';
import 'package:google_mlkit_entity_extraction/google_mlkit_entity_extraction.dart';
import 'package:scroll_to_index/scroll_to_index.dart';
import 'package:bluebubbles/services/ui/chat/send_data.dart';
import 'package:bluebubbles/models/models.dart' show MessageReplyContext;
import 'package:unicode_emojis/unicode_emojis.dart';

class MessageEditEntry {
  final Message message;
  final MessagePart part;
  final SpellCheckTextEditingController controller;
  const MessageEditEntry({required this.message, required this.part, required this.controller});
}

ConversationViewController cvc(Chat chat, {String? tag}) =>
    Get.isRegistered<ConversationViewController>(tag: tag ?? chat.guid)
        ? Get.find<ConversationViewController>(tag: tag ?? chat.guid)
        : Get.put(ConversationViewController(chat, tag_: tag), tag: tag ?? chat.guid);

class ConversationViewController extends StatefulController with GetSingleTickerProviderStateMixin {
  final Chat chat;
  late final String tag;
  bool fromChatCreator = false;
  bool fromSearchResult = false;
  bool addedRecentPhotoReply = false;
  final AutoScrollController scrollController = AutoScrollController();

  ConversationViewController(this.chat, {String? tag_}) {
    tag = tag_ ?? chat.guid;
  }

  // caching items
  final Map<String, VideoController> videoPlayers = {};
  final Map<String, PlayerController> audioPlayers = {};
  final Map<String, Player> audioPlayersDesktop = {};
  final Map<String, List<EntityAnnotation>> mlKitParsedText = {};

  // message view items
  final RxBool showTypingIndicator = false.obs;
  final RxBool showScrollDown = false.obs;
  final RxDouble timestampOffset = 0.0.obs;
  final RxBool inSelectMode = false.obs;
  final RxList<Message> selected = <Message>[].obs;
  final RxList<MessageEditEntry> editing = <MessageEditEntry>[].obs;
  final GlobalKey focusInfoKey = GlobalKey();
  final GlobalKey typingInfoKey = GlobalKey();
  final RxBool recipientNotifsSilenced = false.obs;
  final RxBool showSmartReplyRow = false.obs;
  final RxDouble smartReplyRowHeight = 0.0.obs;
  bool showingOverlays = false;

  /// True while a pointer is actively dragging a [MessageImageGallery] fan of
  /// cards, so the list-wide timestamp-reveal swipe in [MessagesView] can
  /// ignore that drag instead of fighting the gallery for the same gesture.
  bool isGalleryDragging = false;

  /// True while any route is pushed on top of the conversation view route (e.g.
  /// ConversationDetails). Used by onAppResume to skip keyboard auto-focus on mobile.
  bool showingSubRoute = false;
  bool _subjectWasLastFocused = false; // If this is false, then message field was last focused (default)

  FocusNode get lastFocusedNode => _subjectWasLastFocused ? subjectFocusNode : focusNode;
  SpellCheckTextEditingController get lastFocusedTextController =>
      _subjectWasLastFocused ? subjectTextController : textController;

  // text field items
  final RxBool showAttachmentPicker = false.obs;
  RxBool showEmojiPicker = false.obs;
  final GlobalKey textFieldKey = GlobalKey();
  final RxList<PlatformFile> pickedAttachments = <PlatformFile>[].obs;
  final focusNode = FocusNode();
  final subjectFocusNode = FocusNode();
  late final textController = StickerCompositionController(
    serverIdentity: HttpSvc.origin, chatGuid: chat.guid, focusNode: focusNode);
  final stickerDraftError = RxnString();
  final stickerDraftSaveError = RxnString();
  final sendingStickerComposition = false.obs;

  Future<void> saveStickerDraft() async {
    if (stickerDraftError.value != null) return;
    try {
      await PrefsSvc.messaging.saveStickerComposition(
        textController.serverIdentity, chat.guid, textController.serializeDraft());
      stickerDraftSaveError.value = null;
    } catch (error) {
      stickerDraftSaveError.value = error is ArgumentError
        ? 'This sticker draft is too large to save. Shorten the text.'
        : 'Could not save this sticker draft. Keep this conversation open and try again.';
    }
  }

  Future<void> discardSavedStickerDraft() async {
    await PrefsSvc.messaging.saveStickerComposition(textController.serverIdentity, chat.guid, null);
    stickerDraftError.value = null;
  }

  bool restoreStickerDraft() {
    final raw = PrefsSvc.messaging.loadStickerComposition(textController.serverIdentity, chat.guid);
    if (raw == null) return false;
    try {
      textController.restoreDraft(raw);
    } on FormatException {
      stickerDraftError.value = 'The saved sticker draft could not be restored. It has not been sent or deleted.';
    }
    return true;
  }

  Future<void> sendStickerComposition({String? effect,
      StickerFolderService folders = const StickerFolderService()}) async {
    if (sendingStickerComposition.value) return;
    if (stickerDraftError.value != null) throw StateError(stickerDraftError.value!);
    if (!chat.isIMessage || subjectTextController.text.isNotEmpty || replyToMessage != null ||
        effect != null || scheduledDate.value != null || pickedAttachments.isNotEmpty || editing.isNotEmpty) {
      throw StateError('Text with stickers requires an iMessage draft without attachments, a subject, reply, effect, schedule or edit. Your draft is still here.');
    }
    final snapshot = textController.snapshot();
    final standalone = snapshot.entries.length == 1 && snapshot.text == '\uFFFC';
    bool current() => !isClosed && !textController.isDisposed &&
      HttpSvc.origin == snapshot.serverIdentity && chat.guid == snapshot.chatGuid;
    if (!current()) throw StateError('The conversation or server changed. Your draft is still here.');
    sendingStickerComposition.value = true;
    try {
      final capabilities = await HttpSvc.message.stickerCapabilities();
      if (!current()) throw StateError('The conversation or server changed. Your draft is still here.');
      if (capabilities[standalone ? 'stickerSending' : 'stickerComposition'] != true) {
        throw UnsupportedError(standalone ? 'The connected server helper has not enabled native stickers. Your draft is still here.' :
          'The connected server helper has not enabled text with stickers. Your draft is still here.');
      }
      await folders.sendComposition(chat, snapshot.entries, snapshot.text, snapshot.serverIdentity, canQueue: current);
      if (!current()) return;
      if (textController.clearIfUnchanged(snapshot)) {
        await ChatsSvc.setChatTextFieldText(chat, '');
      }
      await saveStickerDraft();
    } finally {
      sendingStickerComposition.value = false;
    }
  }
  late final subjectTextController = SpellCheckTextEditingController(focusNode: subjectFocusNode);
  final RxBool showRecording = false.obs;
  final RxList<Emoji> emojiMatches = <Emoji>[].obs;
  final RxInt emojiSelectedIndex = 0.obs;
  final RxList<Mentionable> mentionMatches = <Mentionable>[].obs;
  final RxInt mentionSelectedIndex = 0.obs;
  final ScrollController emojiScrollController = ScrollController();
  final Rxn<DateTime> scheduledDate = Rxn<DateTime>(null);
  final Rxn<MessageReplyContext> _replyToMessage = Rxn<MessageReplyContext>(null);
  MessageReplyContext? get replyToMessage => _replyToMessage.value;
  set replyToMessage(MessageReplyContext? m) {
    _replyToMessage.value = m;
    if (m != null) {
      lastFocusedNode.requestFocus();
    }
  }

  late final mentionables = chat.handles
      .map((e) => Mentionable(
            handle: e,
          ))
      .toList();

  bool keyboardOpen = false;
  double _keyboardOffset = 0;
  Timer? _scrollDownDebounce;
  Future<void> Function(SendData)? sendFunc;

  /// When set, [_SendAnimationState] will auto-fire this send as soon as it
  /// registers [sendFunc] (i.e. immediately after the widget is built).
  /// Used by ChatCreator to pre-queue a send before navigating to ConversationView.
  SendData? pendingSend;

  /// Completer that resolves once [MessagesView] has finished setting up its
  /// handlers AND its list key (both sync and async loadChunk paths).
  ///
  /// [SendAnimation] waits on this before firing a [pendingSend] so that
  /// [handleNewMessage] → [_listKey.currentState?.insertItem] is guaranteed
  /// to find a mounted [SliverAnimatedList], preventing the silent no-op race.
  Completer<void> _messagesViewReady = Completer<void>();

  /// Called by [MessagesView] once its handlers and list key are fully set up.
  void markMessagesViewReady() {
    if (!_messagesViewReady.isCompleted) {
      _messagesViewReady.complete();
    }
  }

  /// Called by [MessagesView.dispose] so that the next visit starts fresh.
  void resetMessagesViewReady() {
    if (_messagesViewReady.isCompleted) {
      _messagesViewReady = Completer<void>();
    }
  }

  /// Future that resolves once [MessagesView] has fully initialized.
  Future<void> get messagesViewReady => _messagesViewReady.future;

  /// Coordinates message list mutations against the in-flight send animation.
  ///
  /// [SendAnimation] holds this for the duration of its flight so that a
  /// message arriving at the same moment can't insert into the list (or toggle
  /// the smart reply / typing indicator rows) and move the animation's landing
  /// target out from under it. Held work replays as soon as the gate opens.
  /// The send itself is never gated — see [MessageListGate].
  final MessageListGate messageListGate = MessageListGate();

  @override
  void onInit() {
    super.onInit();

    textController.mentionables = mentionables;
    KeyboardVisibilityController().onChange.listen((bool visible) async {
      keyboardOpen = visible;
      if (scrollController.hasClients && scrollController.positions.length == 1) {
        _keyboardOffset = scrollController.offset;
      }
    });

    scrollController.addListener(() {
      if (!scrollController.hasClients || scrollController.positions.length != 1) return;
      if (keyboardOpen &&
          SettingsSvc.settings.hideKeyboardOnScroll.value &&
          scrollController.offset > _keyboardOffset + 100) {
        focusNode.unfocus();
        subjectFocusNode.unfocus();
      }

      if (showScrollDown.value && scrollController.offset >= 500) return;
      if (!showScrollDown.value && scrollController.offset < 500) return;

      if (scrollController.offset >= 500 && !showScrollDown.value) {
        showScrollDown.value = true;
        if (_scrollDownDebounce?.isActive ?? false) _scrollDownDebounce?.cancel();
        _scrollDownDebounce = Timer(const Duration(seconds: 3), () {
          showScrollDown.value = false;
        });
      } else if (showScrollDown.value) {
        showScrollDown.value = false;
      }
    });

    focusNode.addListener(() {
      if (focusNode.hasFocus) {
        _subjectWasLastFocused = false;
      }
    });

    subjectFocusNode.addListener(() {
      if (subjectFocusNode.hasFocus) {
        _subjectWasLastFocused = true;
      }
    });
  }

  @override
  void onClose() {
    messageListGate.dispose();
    updateSmartReplyLayout(visible: false, height: 0);
    for (PlayerController a in audioPlayers.values) {
      a.pausePlayer();
      a.dispose();
    }
    for (Player a in audioPlayersDesktop.values) {
      a.dispose();
    }
    for (VideoController a in videoPlayers.values) {
      a.player.pause();
      a.player.dispose();
    }
    scrollController.dispose();
    super.onClose();
  }

  /// Disposes and evicts the cached [VideoController] for [attachmentGuid] -- call before a
  /// redownload replaces the underlying file, since the cached controller/aspect ratio is from
  /// the old decode and would otherwise get reused as-is.
  void invalidateVideoPlayer(String attachmentGuid) {
    final controller = videoPlayers.remove(attachmentGuid);
    if (controller == null) return;
    controller.player.pause();
    controller.player.dispose();
  }

  Future<void> scrollToBottom() async {
    if (scrollController.positions.isNotEmpty && scrollController.positions.first.extentBefore > 0) {
      await scrollController.animateTo(
        0.0,
        curve: Curves.easeOut,
        duration: const Duration(milliseconds: 300),
      );
    }

    if (SettingsSvc.settings.openKeyboardOnSTB.value) {
      focusNode.requestFocus();
    }
  }

  Future<void> send(SendData data) async {
    await sendFunc?.call(data);
  }

  bool isSelected(String guid) {
    return selected.firstWhereOrNull((e) => e.guid == guid) != null;
  }

  bool isEditing(String guid, int part) {
    return editing.firstWhereOrNull((e) => e.message.guid == guid && e.part.part == part) != null;
  }

  void updateSmartReplyLayout({required bool visible, required double height}) {
    if (showSmartReplyRow.value != visible) {
      showSmartReplyRow.value = visible;
    }

    final nextHeight = visible ? height : 0.0;
    if (smartReplyRowHeight.value != nextHeight) {
      smartReplyRowHeight.value = nextHeight;
    }
  }

  void close() {
    updateSmartReplyLayout(visible: false, height: 0);
    ChatsSvc.setAllInactiveSync();
    Get.delete<ConversationViewController>(tag: tag);
  }

  Future<void> saveReplyToMessageState() async {
    await PrefsInterface.saveReplyToMessageState(
      chat.guid,
      replyToMessage?.message.guid,
      replyToMessage?.partIndex,
    );
  }

  Future<void> loadReplyToMessageState() async {
    final data = await PrefsInterface.loadReplyToMessageState(chat.guid);
    if (data != null) {
      final messageGuid = data['messageGuid'] as String;
      final messagePart = data['messagePart'] as int;
      final message = Message.findOne(guid: messageGuid);
      if (message != null) {
        replyToMessage = MessageReplyContext(message, messagePart);
      }
    }
  }
}
