import 'dart:async';

import 'package:hiddify/features/notice/notice_html.dart';
import 'package:hiddify/features/panel_auth/data/panel_api.dart';
import 'package:hiddify/features/panel_auth/notifier/panel_auth.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

class NoticeItem {
  const NoticeItem({
    required this.id,
    required this.title,
    required this.content,
    required this.important,
    required this.createdAt,
  });

  final int id;
  final String title;
  final String content;
  final bool important;
  final int createdAt;

  String get preview => NoticeHtml.preview(content);
  String get date => noticeDate(createdAt);
}

class NoticeState {
  const NoticeState({
    this.items = const [],
    this.loading = false,
    this.seen = const [],
    this.openUnread = const {},
    this.expandId = 0,
  });

  final List<NoticeItem> items;
  final bool loading;
  final List<int> seen;
  final Set<int> openUnread;
  final int expandId;

  bool unread(int id) => !seen.contains(id);

  bool get hasUnread => items.any((n) => unread(n.id));

  NoticeItem? get strip {
    for (final n in items) {
      if (n.important && unread(n.id)) return n;
    }
    return null;
  }

  NoticeState copyWith({
    List<NoticeItem>? items,
    bool? loading,
    List<int>? seen,
    Set<int>? openUnread,
    int? expandId,
  }) {
    return NoticeState(
      items: items ?? this.items,
      loading: loading ?? this.loading,
      seen: seen ?? this.seen,
      openUnread: openUnread ?? this.openUnread,
      expandId: expandId ?? this.expandId,
    );
  }
}

final noticeProvider = NotifierProvider<NoticeNotifier, NoticeState>(NoticeNotifier.new);

class NoticeNotifier extends Notifier<NoticeState> {
  final PanelApi _api = PanelApi();
  Timer? _timer;
  bool _busy = false;
  int _seenEpoch = 0;

  @override
  NoticeState build() {
    ref.listen(panelAuthProvider.select((s) => s.email), (prev, next) {
      if (prev == next) return;
      state = const NoticeState();
      if (next != null && next.isNotEmpty) refresh();
    });
    _timer?.cancel();
    _timer = Timer.periodic(const Duration(minutes: 30), (_) => refresh());
    ref.onDispose(() => _timer?.cancel());
    Future.microtask(refresh);
    return const NoticeState(loading: true);
  }

  Future<void> refresh() async {
    if (_busy) return;
    final auth = ref.read(panelAuthProvider);
    if (!auth.loggedIn) {
      state = const NoticeState();
      return;
    }
    final token = await ref.read(panelAuthProvider.notifier).currentToken();
    if (token == null || token.isEmpty) {
      state = state.copyWith(loading: false);
      return;
    }
    final key = (auth.email ?? '').trim().toLowerCase();
    if (key.isEmpty) return;
    _busy = true;
    final epoch = _seenEpoch;
    if (state.items.isEmpty) state = state.copyWith(loading: true);
    try {
      final rows = await _api.fetchNotices(token);
      final seen = epoch == _seenEpoch ? await _loadSeen(key) : state.seen;
      if (rows == null) {
        state = state.copyWith(loading: false, seen: seen);
        return;
      }
      final items = <NoticeItem>[];
      for (final row in rows) {
        if (items.length >= 5) break;
        final id = _asInt(row['id']);
        if (id <= 0) continue;
        final tags = row['tags'];
        var important = false;
        if (tags is List) {
          for (final tag in tags) {
            if ('$tag'.trim() == '重要') important = true;
          }
        }
        items.add(NoticeItem(
          id: id,
          title: '${row['title'] ?? ''}',
          content: '${row['content'] ?? ''}',
          important: important,
          createdAt: _asInt(row['created_at']),
        ));
      }
      state = state.copyWith(items: items, loading: false, seen: seen);
    } finally {
      _busy = false;
    }
  }

  /// 打开面板：当前这页全部记成已看过。卡片上的未读点用打开瞬间的快照。
  Future<void> beginOpen(int expandId) async {
    final auth = ref.read(panelAuthProvider);
    final key = (auth.email ?? '').trim().toLowerCase();
    _seenEpoch++;
    final unread = state.items.where((n) => state.unread(n.id)).map((n) => n.id).toSet();
    final seen = [...state.seen];
    for (final item in state.items) {
      if (!seen.contains(item.id)) seen.add(item.id);
    }
    while (seen.length > 50) {
      seen.removeAt(0);
    }
    if (key.isNotEmpty) await _saveSeen(key, seen);
    state = state.copyWith(seen: seen, openUnread: unread, expandId: expandId);
    await refresh();
  }

  Future<List<int>> _loadSeen(String key) async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getStringList('oneray.notice.seen.$key') ?? const [];
    return [for (final id in raw) if (int.tryParse(id) != null) int.parse(id)];
  }

  Future<void> _saveSeen(String key, List<int> ids) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList('oneray.notice.seen.$key', [for (final id in ids) '$id']);
  }

  int _asInt(Object? value) {
    if (value is int) return value;
    if (value is num) return value.toInt();
    return int.tryParse('$value') ?? 0;
  }
}
