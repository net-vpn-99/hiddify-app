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

class _NoticeSheet extends ConsumerStatefulWidget {
  const _NoticeSheet();

  @override
  ConsumerState<_NoticeSheet> createState() => _NoticeSheetState();
}

class _NoticeSheetState extends ConsumerState<_NoticeSheet> {
  int _expanded = 0;

  @override
  void initState() {
    super.initState();
    _expanded = ref.read(noticeProvider).expandId;
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(noticeProvider);
    final tokens = PurchaseTokens.of(context);
    final height = MediaQuery.sizeOf(context).height * 0.85;
    final link = Theme.of(context).brightness == Brightness.dark ? tokens.remaining : const Color(0xFF1F6F59);
    return SizedBox(
      height: height,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
            child: Text('公告', style: TextStyle(fontSize: 17, fontWeight: FontWeight.w600, color: tokens.text)),
          ),
          Expanded(
            child: state.items.isEmpty
                ? Center(
                    child: state.loading
                        ? const SizedBox(width: 28, height: 28, child: CircularProgressIndicator(strokeWidth: 2))
                        : Text('暂时没有公告', style: TextStyle(fontSize: 13, color: tokens.secondary.withValues(alpha: 0.7))),
                  )
                : ListView(
                    padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
                    children: [
                      for (final item in state.items) ...[
                        _NoticeCard(
                          item: item,
                          unread: state.openUnread.contains(item.id),
                          expanded: _expanded == item.id,
                          tokens: tokens,
                          link: link,
                          onTap: () => setState(() => _expanded = _expanded == item.id ? 0 : item.id),
                        ),
                        const SizedBox(height: 8),
                      ],
                      Padding(
                        padding: const EdgeInsets.only(top: 4, bottom: 4),
                        child: Center(
                          child: Text.rich(
                            TextSpan(
                              style: TextStyle(fontSize: 12, color: tokens.secondary.withValues(alpha: 0.7)),
                              children: [
                                const TextSpan(text: '更早的公告在'),
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
    );
  }
}

class _NoticeCard extends StatefulWidget {
  const _NoticeCard({
    required this.item,
    required this.unread,
    required this.expanded,
    required this.tokens,
    required this.link,
    required this.onTap,
  });

  final NoticeItem item;
  final bool unread;
  final bool expanded;
  final PurchaseTokens tokens;
  final Color link;
  final VoidCallback onTap;

  @override
  State<_NoticeCard> createState() => _NoticeCardState();
}

class _NoticeCardState extends State<_NoticeCard> {
  final _recognizers = <TapGestureRecognizer>[];
  List<InlineSpan> _spans = const [];
  String? _html;
  Color? _link;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _syncSpans();
  }

  @override
  void didUpdateWidget(covariant _NoticeCard oldWidget) {
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
    _spans = NoticeHtml.spans(
      widget.item.content,
      TextStyle(fontSize: 13, height: 1.7, color: widget.tokens.text),
      widget.link,
      keep: _recognizers.add,
      onLink: (url) {
        final uri = Uri.tryParse(url);
        if (uri != null && (uri.scheme == 'http' || uri.scheme == 'https')) UriUtils.tryLaunch(uri);
      },
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
    final tokens = widget.tokens;
    final ink3 = tokens.secondary.withValues(alpha: 0.7);
    final dot = Theme.of(context).brightness == Brightness.dark ? const Color(0xFFEC6A5C) : const Color(0xFFD9473A);
    return Material(
      color: tokens.surface,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(14),
        side: BorderSide(color: tokens.border),
      ),
      child: InkWell(
        borderRadius: BorderRadius.circular(14),
        onTap: widget.onTap,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (widget.unread) ...[
                    Padding(
                      padding: const EdgeInsets.only(top: 6),
                      child: Container(
                        width: 7,
                        height: 7,
                        decoration: BoxDecoration(color: dot, shape: BoxShape.circle),
                      ),
                    ),
                    const SizedBox(width: 8),
                  ],
                  Expanded(
                    child: Text(
                      widget.item.title,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(fontSize: 14, fontWeight: FontWeight.w700, color: tokens.text),
                    ),
                  ),
                  if (widget.item.important) ...[
                    const SizedBox(width: 8),
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
                      decoration: BoxDecoration(color: tokens.primary, borderRadius: BorderRadius.circular(5)),
                      child: Text('重要', style: TextStyle(fontSize: 10, fontWeight: FontWeight.w700, color: tokens.onPrimary)),
                    ),
                  ],
                  const SizedBox(width: 8),
                  Transform.rotate(
                    angle: widget.expanded ? 1.5708 : 0,
                    child: Text('›', style: TextStyle(fontSize: 16, height: 1, color: ink3)),
                  ),
                ],
              ),
              if (widget.item.date.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.only(top: 2),
                  child: Text(widget.item.date, style: TextStyle(fontSize: 11, color: ink3)),
                ),
              if (!widget.expanded)
                Padding(
                  padding: const EdgeInsets.only(top: 6),
                  child: Text(
                    widget.item.preview,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(fontSize: 12, color: tokens.secondary),
                  ),
                )
              else
                Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: Text.rich(TextSpan(children: _spans)),
                ),
            ],
          ),
        ),
      ),
    );
  }
}
