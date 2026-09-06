import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:hiddify/features/support/data/support_chat_service.dart';
import 'package:hiddify/features/support/model/support_message.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

/// 在线客服会话状态。见 [SupportChatService] 的说明。
///
/// 没有实时推送（没实现 Chatwoot 的 WebSocket），用轮询代替：
/// - 客服页开着：4 秒一次
/// - 客服页关着、App 还在前台：30 秒一次，收到新回复弹应用内提醒 + 入口红点
/// - App 切后台：停轮询（安卓限制后台运行，这种情况靠 Chatwoot「离线转邮件」兜底）
@immutable
class SupportChatState {
  const SupportChatState({
    this.ready = false,
    this.connecting = false,
    this.sending = false,
    this.error,
    this.messages = const [],
    this.unseenAgentCount = 0,
    this.latestUnseenPreview,
  });

  final bool ready;
  final bool connecting;
  final bool sending;
  final String? error;
  final List<SupportMessage> messages;

  /// 客服页没开时收到的、还没看的客服回复条数（入口红点用）。
  final int unseenAgentCount;
  final String? latestUnseenPreview;

  SupportChatState copyWith({
    bool? ready,
    bool? connecting,
    bool? sending,
    Object? error = _noChange,
    List<SupportMessage>? messages,
    int? unseenAgentCount,
    Object? latestUnseenPreview = _noChange,
  }) {
    return SupportChatState(
      ready: ready ?? this.ready,
      connecting: connecting ?? this.connecting,
      sending: sending ?? this.sending,
      error: error == _noChange ? this.error : error as String?,
      messages: messages ?? this.messages,
      unseenAgentCount: unseenAgentCount ?? this.unseenAgentCount,
      latestUnseenPreview:
          latestUnseenPreview == _noChange ? this.latestUnseenPreview : latestUnseenPreview as String?,
    );
  }

  static const _noChange = Object();
}

final supportChatNotifierProvider =
    NotifierProvider<SupportChatNotifier, SupportChatState>(SupportChatNotifier.new);

class SupportChatNotifier extends Notifier<SupportChatState> {
  static const _kToken = 'support/authToken';
  static const _kSeen = 'support/lastSeenMessageId';

  final _service = SupportChatService();
  final _storage = const FlutterSecureStorage(
    aOptions: AndroidOptions(encryptedSharedPreferences: true),
  );

  String? _authToken;
  bool _hasConversation = false;
  bool _starting = false;
  bool _dialogOpen = false;
  bool _appActive = true;
  int _lastSeenMessageId = 0;
  int _localSeq = 0;

  Timer? _poll;
  List<SupportMessage> _remote = const [];
  final List<SupportMessage> _pending = [];

  // 第一次建会话时带给客服的识别信息。
  String? _email;
  String? _plan;
  String? _version;

  @override
  SupportChatState build() {
    ref.onDispose(() => _poll?.cancel());
    Future.microtask(_loadCache);
    return const SupportChatState();
  }

  // ---- 对外 ----

  /// 打开客服页前调用，把「这是谁 / 什么套餐 / 什么版本」记下来（只有这台设备
  /// 第一次发消息、还没建会话时才带得上；Chatwoot 这套接口没有事后改资料的入口）。
  void bindIdentity({String? email, String? plan, String? version}) {
    if (email != null && email.isNotEmpty) _email = email;
    if (plan != null && plan.isNotEmpty) _plan = plan;
    if (version != null && version.isNotEmpty) _version = version;
  }

  /// 客服页打开。
  Future<void> openChat() async {
    _dialogOpen = true;
    _markAllSeen();
    state = state.copyWith(unseenAgentCount: 0, latestUnseenPreview: null, error: null);
    _applyPoll();
    await _ensureReady();
  }

  /// 客服页关闭。
  Future<void> dialogClosed() async {
    _dialogOpen = false;
    _markAllSeen();
    await _saveCache();
    _applyPoll();
  }

  /// App 切前台 / 后台。
  void setAppActive(bool active) {
    if (_appActive == active) return;
    _appActive = active;
    if (!active) {
      _poll?.cancel();
      _poll = null;
    } else if (_authToken != null) {
      _fetchMessages();
      _applyPoll();
    }
  }

  Future<void> refreshNow() => _fetchMessages();

  Future<void> sendText(String text) async {
    final trimmed = text.trim();
    if (trimmed.isEmpty) return;
    if (_authToken == null) {
      state = state.copyWith(error: '会话还没准备好，请稍等几秒再发');
      await _ensureReady();
      return;
    }
    final local = SupportMessage(
      id: _nextLocalId(),
      text: trimmed,
      mine: true,
      pending: true,
      timeMs: DateTime.now().millisecondsSinceEpoch,
    );
    _pending.add(local);
    state = state.copyWith(messages: _display(), error: null);
    await _doSendText(local);
  }

  Future<void> sendImages(List<String> paths) async {
    if (paths.isEmpty) return;
    if (_authToken == null) {
      state = state.copyWith(error: '会话还没准备好，请稍等几秒再发');
      await _ensureReady();
      return;
    }
    final locals = <SupportMessage>[];
    for (final p in paths) {
      final local = SupportMessage(
        id: _nextLocalId(),
        mine: true,
        pending: true,
        localImagePath: p,
        timeMs: DateTime.now().millisecondsSinceEpoch,
      );
      _pending.add(local);
      locals.add(local);
    }
    state = state.copyWith(messages: _display(), error: null);
    // 一张一张发：第一张会建会话，之后的才是追加，避免并发建出两条会话。
    for (final local in locals) {
      await _doSendImage(local);
    }
  }

  Future<void> retry(SupportMessage msg) async {
    final idx = _pending.indexWhere((m) => m.id == msg.id);
    if (idx < 0 || !_pending[idx].failed) return;
    _pending[idx] = _pending[idx].copyWith(pending: true, failed: false);
    state = state.copyWith(messages: _display(), error: null);
    final m = _pending[idx];
    if (m.localImagePath != null && m.localImagePath!.isNotEmpty) {
      await _doSendImage(m);
    } else {
      await _doSendText(m);
    }
  }

  // ---- 身份 / 握手 ----

  Future<void> _loadCache() async {
    try {
      _authToken = await _storage.read(key: _kToken);
      _lastSeenMessageId = int.tryParse(await _storage.read(key: _kSeen) ?? '') ?? 0;
    } catch (_) {}
    if (_authToken != null && _authToken!.isNotEmpty) {
      state = state.copyWith(ready: true);
      if (_appActive) {
        _fetchMessages();
        _applyPoll();
      }
    }
  }

  Future<void> _saveCache() async {
    try {
      if (_authToken != null) await _storage.write(key: _kToken, value: _authToken);
      await _storage.write(key: _kSeen, value: '$_lastSeenMessageId');
    } catch (_) {}
  }

  Future<void> _ensureReady() async {
    if (_authToken != null) {
      if (!state.ready) state = state.copyWith(ready: true, connecting: false);
      await _fetchMessages();
      _applyPoll();
      return;
    }
    if (_starting) return;
    _starting = true;
    state = state.copyWith(connecting: true, error: null);
    try {
      final token = await _service.fetchAuthToken();
      if (token == null || token.isEmpty) {
        _starting = false;
        state = state.copyWith(connecting: false, error: '联系客服暂时打不开，请稍后重试');
        return;
      }
      _authToken = token;
      _hasConversation = false;
      await _saveCache();
      await _checkConversation();
    } catch (_) {
      _starting = false;
      state = state.copyWith(connecting: false, error: '联系客服暂时打不开，请稍后重试');
    }
  }

  Future<void> _checkConversation() async {
    try {
      final r = await _service.conversationStatus(_authToken!);
      if (r.status == 401 || r.status == 404) {
        await _resetAndRetry();
        return;
      }
      _hasConversation = r.exists;
    } catch (_) {
      // 网络抖动，当作还没有会话，之后发消息时会建。
      _hasConversation = false;
    }
    _starting = false;
    state = state.copyWith(ready: true, connecting: false, error: null);
    await _fetchMessages();
    _applyPoll();
  }

  Future<void> _resetAndRetry() async {
    _authToken = null;
    _hasConversation = false;
    _starting = false;
    await _saveCache();
    await _ensureReady();
  }

  // ---- 收消息 / 轮询 ----

  void _applyPoll() {
    _poll?.cancel();
    if (_authToken == null || !_appActive) {
      _poll = null;
      return;
    }
    final d = _dialogOpen ? const Duration(seconds: 4) : const Duration(seconds: 30);
    _poll = Timer.periodic(d, (_) => _fetchMessages());
  }

  Future<void> _fetchMessages() async {
    if (_authToken == null) return;
    final list = await _service.fetchMessages(_authToken!);
    if (list == null) return; // 轮询失败静默重试下一轮

    var maxAgentId = _lastSeenMessageId;
    String? preview;
    for (final m in list) {
      if (m.mine || m.system) continue;
      if (m.id > maxAgentId) {
        maxAgentId = m.id;
        preview = m.text.isEmpty ? '[图片]' : m.text;
      }
    }
    final hasNewAgentReply = maxAgentId > _lastSeenMessageId;
    _remote = list;

    if (_dialogOpen) {
      // 页面开着 = 正在看，直接算已读，不弹提醒。
      _lastSeenMessageId = maxAgentId;
      await _saveCache();
      state = state.copyWith(messages: _display(), unseenAgentCount: 0, latestUnseenPreview: null);
    } else if (hasNewAgentReply) {
      _lastSeenMessageId = maxAgentId;
      await _saveCache();
      state = state.copyWith(
        messages: _display(),
        unseenAgentCount: state.unseenAgentCount + 1,
        latestUnseenPreview: preview,
      );
    } else {
      state = state.copyWith(messages: _display());
    }
  }

  // ---- 发消息 ----

  Future<void> _doSendText(SupportMessage local) async {
    state = state.copyWith(sending: true);
    final creating = !_hasConversation;
    int status;
    try {
      status = await _service.sendText(
        _authToken!,
        local.text,
        createConversation: creating,
        email: _email,
        plan: _plan,
        version: _version,
      );
    } catch (_) {
      status = 0;
    }
    state = state.copyWith(sending: false);
    await _afterSend(local, status, creating);
  }

  Future<void> _doSendImage(SupportMessage local) async {
    state = state.copyWith(sending: true);
    final creating = !_hasConversation;
    int status;
    try {
      status = await _service.sendImage(_authToken!, File(local.localImagePath!));
    } catch (_) {
      status = 0;
    }
    state = state.copyWith(sending: false);
    await _afterSend(local, status, creating);
  }

  Future<void> _afterSend(SupportMessage local, int status, bool creating) async {
    if (status >= 200 && status < 300) {
      if (creating) _hasConversation = true;
      _pending.removeWhere((m) => m.id == local.id);
      state = state.copyWith(messages: _display(), error: null);
      await _fetchMessages();
    } else if (status == 401 || status == 404) {
      _markFailed(local);
      await _resetAndRetry();
      state = state.copyWith(error: '连接已过期，正在重连，请重发一次');
    } else {
      _markFailed(local);
      state = state.copyWith(error: '发送失败，点消息旁的「重试」');
    }
  }

  void _markFailed(SupportMessage local) {
    final idx = _pending.indexWhere((m) => m.id == local.id);
    if (idx < 0) return;
    _pending[idx] = _pending[idx].copyWith(pending: false, failed: true);
    state = state.copyWith(messages: _display());
  }

  // ---- 小工具 ----

  void _markAllSeen() {
    for (final m in _remote) {
      if (!m.mine && !m.system) {
        _lastSeenMessageId = math.max(_lastSeenMessageId, m.id);
      }
    }
  }

  int _nextLocalId() => --_localSeq; // -1, -2, ...

  List<SupportMessage> _display() => [..._remote, ..._pending];
}
