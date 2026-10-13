import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:hiddify/core/model/constants.dart';
import 'package:hiddify/features/common/guide_card.dart';
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
  // 10-13 跟引导卡一样：浅底上浮一张随内容高度的白卡（Windows NoticePanel.qml 同款），不再是底部抽屉。
  await showDialog<void>(
    context: context,
    barrierColor: guideCanvasColor(context),
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

// 公告（10-13 改轻，跟邮件一个感觉；两端统一，Windows 是 NoticePanel.qml，两边一起改）：
//   浅色底上浮一张白卡，卡片上方有光速雷达的标志，卡片高度跟着内容走（内容少就小，不留大片空白）。
//   列表：不套框，条目之间一根细线；没看过的金点 + 粗标题，下面一行小字「日期 · 摘要」；「重要」是浅金小标签。
//   详情：点一条，卡片换成这一条，像读一封邮件；标题居中，短公告正文也居中；
//   正文里单独一段的那个链接另起一个金色整行按钮。卡片下面「‹ 返回公告列表」。
final _soloLink = RegExp(r'<p>\s*<a href="([^"]*)">([\s\S]*?)</a>\s*</p>');
final _anyLink = RegExp(r'<a href="([^"]*)">([\s\S]*?)</a>');

({String href, String text})? _firstLink(String html) {
  final m = _soloLink.firstMatch(html) ?? _anyLink.firstMatch(html);
  if (m == null) return null;
  final text = m.group(2)!.replaceAll(RegExp('<[^>]*>'), '').trim();
  return text.isEmpty ? null : (href: m.group(1)!, text: text);
}

// 短公告（两三句、没有列表）正文居中；长的、带列表的还是靠左，不然难读。
bool _isShort(String html) {
  if (RegExp(r'<(ul|ol|li|table|h[1-6])\b', caseSensitive: false).hasMatch(html)) return false;
  return html.replaceAll(RegExp('<[^>]*>'), '').replaceAll(RegExp('&[a-z]+;'), ' ').trim().length <= 140;
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
    final maxCard = MediaQuery.sizeOf(context).height * 0.7;
    final link = tokens.warning;
    final ink3 = tokens.secondary.withValues(alpha: 0.7);
    NoticeItem? current;
    for (final it in state.items) {
      if (it.id == _open) current = it;
    }

    final Widget content;
    if (current != null) {
      content = _NoticeDetail(item: current, tokens: tokens, link: link);
    } else if (state.items.isEmpty) {
      content = SizedBox(
        height: 120,
        child: Center(
          child: state.loading
              ? const SizedBox(width: 28, height: 28, child: CircularProgressIndicator(strokeWidth: 2))
              : Text('暂时没有公告', style: TextStyle(fontSize: 13, color: ink3)),
        ),
      );
    } else {
      content = ListView(
        shrinkWrap: true,
        padding: const EdgeInsets.fromLTRB(14, 0, 14, 10),
        children: [
          for (var i = 0; i < state.items.length; i++)
            _NoticeRow(
              item: state.items[i],
              unread: state.openUnread.contains(state.items[i].id),
              last: i == state.items.length - 1,
              tokens: tokens,
              onTap: () => setState(() => _open = state.items[i].id),
            ),
        ],
      );
    }

    return PopScope(
      canPop: current == null,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) setState(() => _open = 0);
      },
      child: Dialog(
        backgroundColor: Colors.transparent,
        surfaceTintColor: Colors.transparent,
        shadowColor: Colors.transparent,
        elevation: 0,
        insetPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 24),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 460),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const GuideBrandRow(),
              Container(
                constraints: BoxConstraints(maxHeight: maxCard),
                decoration: guideCardDecoration(context),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    SizedBox(
                      height: 58,
                      child: Stack(
                        alignment: Alignment.center,
                        children: [
                          if (current == null)
                            Text('公告', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w500, color: tokens.text)),
                          Positioned(
                            right: 6,
                            top: 8,
                            child: IconButton(
                              tooltip: '关闭公告',
                              icon: Icon(Icons.close_rounded, size: 20, color: ink3),
                              onPressed: () => Navigator.of(context).pop(),
                            ),
                          ),
                        ],
                      ),
                    ),
                    Flexible(child: content),
                    const SizedBox(height: 14),
                  ],
                ),
              ),
              const SizedBox(height: 10),
              // 卡片下面一行小字：列表时是「更早的公告」，看某一条时是「返回列表」。
              if (current != null)
                Center(
                  child: TextButton(
                    style: TextButton.styleFrom(foregroundColor: tokens.secondary, minimumSize: const Size(48, 40)),
                    onPressed: () => setState(() => _open = 0),
                    child: const Text('‹  返回公告列表', style: TextStyle(fontSize: 13)),
                  ),
                )
              else if (state.items.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 10),
                  child: Center(
                    child: Text.rich(
                      TextSpan(
                        style: TextStyle(fontSize: 12, color: ink3),
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
    final preview = unread ? item.preview : '';
    final meta = item.date.isNotEmpty && preview.isNotEmpty ? '${item.date}  ·  $preview' : '${item.date}$preview';
    return InkWell(
      borderRadius: BorderRadius.circular(10),
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.fromLTRB(10, 13, 10, 13),
        decoration: BoxDecoration(
          border: last ? null : Border(bottom: BorderSide(color: tokens.border.withValues(alpha: 0.6))),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.only(top: 7),
              child: Container(
                width: 7,
                height: 7,
                decoration: BoxDecoration(color: unread ? tokens.primary : Colors.transparent, shape: BoxShape.circle),
              ),
            ),
            const SizedBox(width: 9),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
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
                        Container(
                          padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 1),
                          decoration: BoxDecoration(color: tokens.selected, borderRadius: BorderRadius.circular(9)),
                          child: Text('重要', style: TextStyle(fontSize: 11, color: tokens.warning)),
                        ),
                      ],
                    ],
                  ),
                  if (meta.isNotEmpty)
                    Padding(
                      padding: const EdgeInsets.only(top: 4),
                      child: Text(
                        meta,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(fontSize: 12, color: ink3),
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
  bool _centered = false;
  // 正文比卡片长时，底部渐隐 + 「下滑查看更多」（10-14 运营真机：长公告看不出下面还有内容）。
  final _scroll = ScrollController();
  bool _more = false;

  @override
  void initState() {
    super.initState();
    _scroll.addListener(_checkMore);
  }

  void _checkMore() {
    if (!_scroll.hasClients) return;
    final p = _scroll.position;
    final more = p.maxScrollExtent - p.pixels > 8;
    if (more != _more) setState(() => _more = more);
  }

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
    _centered = _isShort(body);
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
    _scroll.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final t = widget.tokens;
    final button = _button;
    // 换了一条公告 / 第一次排版完：内容高度变了，重新看一下下面还有没有。
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _checkMore();
    });
    final list = ListView(
      controller: _scroll,
      shrinkWrap: true,
      padding: const EdgeInsets.fromLTRB(26, 0, 26, 10),
      children: [
        Text(
          widget.item.title,
          textAlign: TextAlign.center,
          style: TextStyle(fontSize: 20, fontWeight: FontWeight.w500, color: t.text, height: 1.3),
        ),
        if (widget.item.date.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(top: 6),
            child: Text(
              widget.item.date,
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 12, color: t.secondary.withValues(alpha: 0.7)),
            ),
          ),
        const SizedBox(height: 18),
        Center(
          child: ConstrainedBox(
            constraints: BoxConstraints(maxWidth: _centered ? 320 : double.infinity),
            child: Text.rich(
              TextSpan(children: _spans),
              textAlign: _centered ? TextAlign.center : TextAlign.start,
            ),
          ),
        ),
        if (button != null) ...[
          const SizedBox(height: 24),
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
    return Stack(
      children: [
        Scrollbar(controller: _scroll, child: list),
        if (_more)
          Positioned(
            left: 0,
            right: 0,
            bottom: 0,
            child: IgnorePointer(
              child: Container(
                height: 64,
                alignment: Alignment.bottomCenter,
                padding: const EdgeInsets.only(bottom: 4),
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    colors: [t.raised.withValues(alpha: 0), t.raised],
                  ),
                ),
                child: Text('下滑查看更多  ⌄', style: TextStyle(fontSize: 12, color: t.secondary)),
              ),
            ),
          ),
      ],
    );
  }
}
