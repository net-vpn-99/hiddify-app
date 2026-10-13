import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:hiddify/core/model/constants.dart';
import 'package:hiddify/features/notice/notice_html.dart';
import 'package:hiddify/features/notice/notice_store.dart';
import 'package:hiddify/features/purchase/widget/purchase_tokens.dart';
import 'package:hiddify/utils/uri_utils.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

const _bell = '''
<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24" fill="none" stroke="#000" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round">
  <path d="M6 8a6 6 0 1 1 12 0c0 7 3 9 3 9H3s3-2 3-9"/>
  <path d="M10.3 21a1.94 1.94 0 0 0 3.4 0"/>
</svg>
''';

Future<void> showNoticeSheet(BuildContext context, WidgetRef ref, {int expandId = 0}) async {
  final notifier = ref.read(noticeProvider.notifier);
  await notifier.beginOpen(expandId);
  if (!context.mounted) return;
  await showModalBottomSheet<void>(
    context: context,
    showDragHandle: true,
    isScrollControlled: true,
    builder: (context) => const _NoticeSheet(),
  );
}

class NoticeBell extends ConsumerWidget {
  const NoticeBell({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final unread = ref.watch(noticeProvider.select((s) => s.hasUnread));
    final theme = Theme.of(context);
    final color = theme.colorScheme.primary;
    final ring = theme.appBarTheme.backgroundColor ?? theme.colorScheme.surface;
    final dot = theme.brightness == Brightness.dark ? const Color(0xFFEC6A5C) : const Color(0xFFD9473A);
    return TextButton(
      style: TextButton.styleFrom(
        padding: EdgeInsets.zero,
        minimumSize: const Size(40, 40),
        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
        visualDensity: VisualDensity.compact,
        foregroundColor: color,
      ),
      onPressed: () => showNoticeSheet(context, ref),
      child: SizedBox(
        width: 40,
        height: 40,
        child: Stack(
          alignment: Alignment.center,
          children: [
            SvgPicture.string(
              _bell,
              width: 20,
              height: 20,
              colorFilter: ColorFilter.mode(color, BlendMode.srcIn),
            ),
            if (unread)
              Positioned(
                top: 6,
                right: 6,
                child: Container(
                  width: 11,
                  height: 11,
                  alignment: Alignment.center,
                  decoration: BoxDecoration(color: ring, shape: BoxShape.circle),
                  child: Container(
                    width: 7,
                    height: 7,
                    decoration: BoxDecoration(color: dot, shape: BoxShape.circle),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class NoticeStrip extends ConsumerWidget {
  const NoticeStrip({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final item = ref.watch(noticeProvider.select((s) => s.strip));
    if (item == null) return const SizedBox.shrink();
    final tokens = PurchaseTokens.of(context);
    final ink3 = tokens.secondary.withValues(alpha: 0.7);
    return Padding(
      padding: const EdgeInsets.fromLTRB(14, 8, 14, 0),
      child: Material(
        color: tokens.selected,
        borderRadius: BorderRadius.circular(10),
        child: InkWell(
          borderRadius: BorderRadius.circular(10),
          onTap: () => showNoticeSheet(context, ref, expandId: item.id),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
            child: Row(
              children: [
                Text('重要', style: TextStyle(fontSize: 12, fontWeight: FontWeight.w700, color: tokens.text)),
                Expanded(
                  child: Text(
                    ' · ${item.title}',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(fontSize: 12, color: tokens.text),
                  ),
                ),
                Text(' ›', style: TextStyle(fontSize: 12, color: ink3)),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

// 公告（10-13 改轻，跟邮件一个感觉；两端统一，Windows 是 NoticePanel.qml）：
//   列表：不套框，条目之间一根细线；没看过的金点 + 粗标题 + 一行摘要，看过的只剩普通字标题和日期。
//   详情：点一条，整个面板换成这一条，像读一封邮件；正文里单独一段的链接另起一个金色整行按钮。
final _soloLink = RegExp(r'<p>\s*<a href="([^"]*)">([\s\S]*?)</a>\s*</p>');
final _anyLink = RegExp(r'<a href="([^"]*)">([\s\S]*?)</a>');

({String href, String text})? _firstLink(String html) {
  final m = _soloLink.firstMatch(html) ?? _anyLink.firstMatch(html);
  if (m == null) return null;
  final text = m.group(2)!.replaceAll(RegExp('<[^>]*>'), '').trim();
  return text.isEmpty ? null : (href: m.group(1)!, text: text);
}

void _openLink(String url) {
  final uri = Uri.tryParse(url);
  if (uri != null && (uri.scheme == 'http' || uri.scheme == 'https')) UriUtils.tryLaunch(uri);
}

class _NoticeSheet extends ConsumerStatefulWidget {
  const _NoticeSheet();

  @override
  ConsumerState<_NoticeSheet> createState() => _NoticeSheetState();
}

class _NoticeSheetState extends ConsumerState<_NoticeSheet> {
  int _open = 0;

  @override
  void initState() {
    super.initState();
    _open = ref.read(noticeProvider).expandId;
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(noticeProvider);
    final tokens = PurchaseTokens.of(context);
    final height = MediaQuery.sizeOf(context).height * 0.85;
    final link = tokens.warning;
    NoticeItem? current;
    for (final it in state.items) {
      if (it.id == _open) current = it;
    }
    return PopScope(
      canPop: current == null,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) setState(() => _open = 0);
      },
      child: SizedBox(
        height: height,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(22, 0, 16, 8),
              child: current == null
                  ? Text('公告', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w600, color: tokens.text))
                  : Align(
                      alignment: Alignment.centerLeft,
                      child: TextButton(
                        style: TextButton.styleFrom(
                          foregroundColor: tokens.secondary,
                          padding: EdgeInsets.zero,
                          minimumSize: const Size(48, 36),
                        ),
                        onPressed: () => setState(() => _open = 0),
                        child: const Text('‹  公告', style: TextStyle(fontSize: 14)),
                      ),
                    ),
            ),
            Expanded(
              child: current != null
                  ? _NoticeDetail(item: current, tokens: tokens, link: link)
                  : state.items.isEmpty
                      ? Center(
                          child: state.loading
                              ? const SizedBox(width: 28, height: 28, child: CircularProgressIndicator(strokeWidth: 2))
                              : Text('暂时没有公告', style: TextStyle(fontSize: 13, color: tokens.secondary.withValues(alpha: 0.7))),
                        )
                      : ListView(
                          padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
                          children: [
                            for (var i = 0; i < state.items.length; i++)
                              _NoticeRow(
                                item: state.items[i],
                                unread: state.openUnread.contains(state.items[i].id),
                                last: i == state.items.length - 1,
                                tokens: tokens,
                                onTap: () => setState(() => _open = state.items[i].id),
                              ),
                            Padding(
                              padding: const EdgeInsets.only(top: 14, bottom: 4),
                              child: Center(
                                child: Text.rich(
                                  TextSpan(
                                    style: TextStyle(fontSize: 12, color: tokens.secondary.withValues(alpha: 0.7)),
                                    children: [
                                      const TextSpan(text: '更早的公告在 '),
                                      WidgetSpan(
                                        alignment: PlaceholderAlignment.middle,
                                        child: GestureDetector(
                                          onTap: () => UriUtils.tryLaunch(Uri.parse(Constants.panelProfileUrl)),
                                          child: Text('官网会员中心', style: TextStyle(fontSize: 12, color: link)),
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                              ),
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

class _NoticeRow extends StatelessWidget {
  const _NoticeRow({
    required this.item,
    required this.unread,
    required this.last,
    required this.tokens,
    required this.onTap,
  });

  final NoticeItem item;
  final bool unread;
  final bool last;
  final PurchaseTokens tokens;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final ink3 = tokens.secondary.withValues(alpha: 0.7);
    return InkWell(
      borderRadius: BorderRadius.circular(10),
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.fromLTRB(10, 14, 10, 14),
        decoration: BoxDecoration(
          border: last ? null : Border(bottom: BorderSide(color: tokens.border.withValues(alpha: 0.6))),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Container(
                  width: 7,
                  height: 7,
                  decoration: BoxDecoration(color: unread ? tokens.primary : Colors.transparent, shape: BoxShape.circle),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    item.title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 14,
                      fontWeight: unread ? FontWeight.w600 : FontWeight.w400,
                      color: unread ? tokens.text : tokens.secondary,
                    ),
                  ),
                ),
                if (item.important) ...[
                  const SizedBox(width: 8),
                  Text('重要', style: TextStyle(fontSize: 11, fontWeight: FontWeight.w600, color: tokens.warning)),
                ],
                if (item.date.isNotEmpty) ...[
                  const SizedBox(width: 8),
                  Text(item.date, style: TextStyle(fontSize: 12, color: ink3)),
                ],
              ],
            ),
            if (unread && item.preview.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(left: 15, top: 4),
                child: Text(
                  item.preview,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(fontSize: 13, color: tokens.secondary),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _NoticeDetail extends StatefulWidget {
  const _NoticeDetail({required this.item, required this.tokens, required this.link});

  final NoticeItem item;
  final PurchaseTokens tokens;
  final Color link;

  @override
  State<_NoticeDetail> createState() => _NoticeDetailState();
}

class _NoticeDetailState extends State<_NoticeDetail> {
  final _recognizers = <TapGestureRecognizer>[];
  List<InlineSpan> _spans = const [];
  String? _html;
  Color? _link;
  ({String href, String text})? _button;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _syncSpans();
  }

  @override
  void didUpdateWidget(covariant _NoticeDetail oldWidget) {
    super.didUpdateWidget(oldWidget);
    _syncSpans();
  }

  void _syncSpans() {
    if (_html == widget.item.content && _link == widget.link) return;
    _link = widget.link;
    for (final r in _recognizers) {
      r.dispose();
    }
    _recognizers.clear();
    _html = widget.item.content;
    _button = _firstLink(widget.item.content);
    // 单独一段的那个链接已经变成底部金色按钮，正文里不再重复显示。
    final body = _button != null ? widget.item.content.replaceFirst(_soloLink, '') : widget.item.content;
    _spans = NoticeHtml.spans(
      body,
      TextStyle(fontSize: 14, height: 1.6, color: widget.tokens.text),
      widget.link,
      keep: _recognizers.add,
      onLink: _openLink,
    );
  }

  @override
  void dispose() {
    for (final r in _recognizers) {
      r.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final t = widget.tokens;
    final button = _button;
    return ListView(
      padding: const EdgeInsets.fromLTRB(24, 0, 24, 24),
      children: [
        Text(widget.item.title, style: TextStyle(fontSize: 19, fontWeight: FontWeight.w600, color: t.text, height: 1.35)),
        if (widget.item.date.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(top: 6),
            child: Text(widget.item.date, style: TextStyle(fontSize: 12, color: t.secondary.withValues(alpha: 0.7))),
          ),
        const SizedBox(height: 16),
        Text.rich(TextSpan(children: _spans)),
        if (button != null) ...[
          const SizedBox(height: 22),
          SizedBox(
            height: 48,
            child: FilledButton(
              style: FilledButton.styleFrom(
                backgroundColor: t.primary,
                foregroundColor: t.onPrimary,
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                textStyle: const TextStyle(fontSize: 15, fontWeight: FontWeight.w500),
              ),
              onPressed: () => _openLink(button.href),
              child: Text(button.text, maxLines: 1, overflow: TextOverflow.ellipsis),
            ),
          ),
        ],
      ],
    );
  }
}
