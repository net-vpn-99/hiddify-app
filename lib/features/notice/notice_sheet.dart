import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:hiddify/core/model/constants.dart';
import 'package:hiddify/features/common/guide_card.dart';
import 'package:hiddify/features/common/line_icon.dart';
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

// 公告（10-15 改版，参照 GoMami；两端统一，Windows 是 NoticePanel.qml，两边一起改）：
//   一张白卡，所有东西都在卡里：顶栏（列表：铃铛 +「公告」；详情：「‹ 全部公告」）+ ✕，下面一根细线。
//   列表：粗标题 + 灰色一行「日期 · 摘要」，右边「新」/「重要」小标签和「›」。
//   详情：灰色小字日期（+「重要」）→ 大标题 → 正文，一律靠左。正文按块排（NoticeHtml.blocks）：
//   段落、条目（圆点折行对齐文字）、小标题、重点横幅（<blockquote>）、单独一行的链接 → 卡片底部金色按钮。
//   长公告只留滚动条 + 底部淡出，不写「下滑查看更多」。

void _openLink(String url) {
  final uri = Uri.tryParse(url);
  if (uri != null && (uri.scheme == 'http' || uri.scheme == 'https')) UriUtils.tryLaunch(uri);
}

// 「重要」用的浅红（Windows Theme.fault 同色）。
Color _alert(BuildContext context) =>
    Theme.of(context).brightness == Brightness.dark ? const Color(0xFFD59A57) : const Color(0xFF9A581F);

class _Pill extends StatelessWidget {
  const _Pill(this.label, {this.alert = false});
  final String label;
  final bool alert;

  @override
  Widget build(BuildContext context) {
    final t = PurchaseTokens.of(context);
    final fg = alert ? _alert(context) : t.warning;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
      decoration: BoxDecoration(
        color: alert ? fg.withValues(alpha: 0.12) : t.selected,
        borderRadius: BorderRadius.circular(6),
      ),
      child: Text(label, style: TextStyle(fontSize: 11, fontWeight: FontWeight.w500, color: fg)),
    );
  }
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
    final t = PurchaseTokens.of(context);
    final maxCard = MediaQuery.sizeOf(context).height * 0.75;
    final ink3 = t.secondary.withValues(alpha: 0.7);
    final line = t.border.withValues(alpha: 0.6);
    NoticeItem? current;
    for (final it in state.items) {
      if (it.id == _open) current = it;
    }

    final Widget body;
    if (current != null) {
      body = _NoticeDetail(key: ValueKey(current.id), item: current);
    } else if (state.items.isEmpty) {
      body = SizedBox(
        height: 120,
        child: Center(
          child: state.loading
              ? const SizedBox(width: 28, height: 28, child: CircularProgressIndicator(strokeWidth: 2))
              : Text('暂时没有公告', style: TextStyle(fontSize: 13, color: ink3)),
        ),
      );
    } else {
      body = ListView(
        shrinkWrap: true,
        padding: const EdgeInsets.symmetric(vertical: 6),
        children: [
          for (var i = 0; i < state.items.length; i++)
            _NoticeRow(
              item: state.items[i],
              unread: state.openUnread.contains(state.items[i].id),
              last: i == state.items.length - 1,
              onTap: () => setState(() => _open = state.items[i].id),
            ),
        ],
      );
    }

    // 顶栏：列表是铃铛 +「公告」，详情是「‹ 全部公告」（点它回列表）；右边 ✕。
    final head = SizedBox(
      height: 60,
      child: Row(
        children: [
          if (current == null) ...[
            const SizedBox(width: 24),
            Container(
              width: 30,
              height: 30,
              alignment: Alignment.center,
              decoration: BoxDecoration(color: t.selected, borderRadius: BorderRadius.circular(8)),
              child: LineIcon(LineIconName.bell, color: t.warning, size: 17),
            ),
            const SizedBox(width: 10),
            Text('公告', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700, color: t.text)),
          ] else ...[
            const SizedBox(width: 12),
            TextButton(
              style: TextButton.styleFrom(
                foregroundColor: t.warning,
                padding: const EdgeInsets.symmetric(horizontal: 10),
                minimumSize: const Size(48, 40),
              ),
              onPressed: () => setState(() => _open = 0),
              child: const Text('‹  全部公告', style: TextStyle(fontSize: 14, fontWeight: FontWeight.w500)),
            ),
          ],
          const Spacer(),
          IconButton(
            tooltip: '关闭公告',
            icon: Icon(Icons.close_rounded, size: 20, color: ink3),
            onPressed: () => Navigator.of(context).pop(),
          ),
          const SizedBox(width: 10),
        ],
      ),
    );

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
          constraints: BoxConstraints(maxWidth: 460, maxHeight: maxCard),
          child: DecoratedBox(
            decoration: guideCardDecoration(context).copyWith(borderRadius: BorderRadius.circular(16)),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                head,
                Divider(height: 1, thickness: 1, color: line),
                Flexible(child: body),
                if (current == null && state.items.isNotEmpty) ...[
                  Divider(height: 1, thickness: 1, color: line),
                  SizedBox(
                    height: 52,
                    child: Center(
                      child: TextButton(
                        style: TextButton.styleFrom(foregroundColor: t.warning),
                        onPressed: () => UriUtils.tryLaunch(Uri.parse(Constants.panelProfileUrl)),
                        child: const Text('更早的公告在官网会员中心  →',
                            style: TextStyle(fontSize: 13, fontWeight: FontWeight.w500)),
                      ),
                    ),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _NoticeRow extends StatelessWidget {
  const _NoticeRow({required this.item, required this.unread, required this.last, required this.onTap});

  final NoticeItem item;
  final bool unread;
  final bool last;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final t = PurchaseTokens.of(context);
    final ink3 = t.secondary.withValues(alpha: 0.7);
    final meta = item.date.isNotEmpty && item.preview.isNotEmpty ? '${item.date}  ·  ${item.preview}' : '${item.date}${item.preview}';
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 10),
      child: InkWell(
        borderRadius: BorderRadius.circular(10),
        onTap: onTap,
        child: Container(
          height: 70,
          padding: const EdgeInsets.symmetric(horizontal: 14),
          decoration: BoxDecoration(
            border: last ? null : Border(bottom: BorderSide(color: t.border.withValues(alpha: 0.6))),
          ),
          child: Row(
            children: [
              Expanded(
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      item.title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 14,
                        fontWeight: unread ? FontWeight.w700 : FontWeight.w400,
                        color: t.text,
                      ),
                    ),
                    if (meta.isNotEmpty)
                      Padding(
                        padding: const EdgeInsets.only(top: 5),
                        child: Text(meta, maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 12, color: ink3)),
                      ),
                  ],
                ),
              ),
              if (unread) ...[const SizedBox(width: 10), const _Pill('新')],
              if (item.important) ...[const SizedBox(width: 10), const _Pill('重要', alert: true)],
              const SizedBox(width: 10),
              Text('›', style: TextStyle(fontSize: 20, color: ink3)),
            ],
          ),
        ),
      ),
    );
  }
}

class _NoticeDetail extends StatefulWidget {
  const _NoticeDetail({super.key, required this.item});

  final NoticeItem item;

  @override
  State<_NoticeDetail> createState() => _NoticeDetailState();
}

class _NoticeDetailState extends State<_NoticeDetail> {
  final _recognizers = <TapGestureRecognizer>[];
  late final List<NoticeBlock> _blocks = NoticeHtml.blocks(widget.item.content);
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
    final more = p.maxScrollExtent - p.pixels > 4;
    if (more != _more) setState(() => _more = more);
  }

  @override
  void dispose() {
    for (final r in _recognizers) {
      r.dispose();
    }
    _scroll.dispose();
    super.dispose();
  }

  Widget _block(NoticeBlock b, PurchaseTokens t) {
    final h = b.kind == 'h';
    final style = TextStyle(
      fontSize: h ? 15 : 14,
      height: h ? 1.3 : 1.55,
      fontWeight: h ? FontWeight.w700 : FontWeight.w400,
      color: h ? t.text : t.text.withValues(alpha: 0.82),
    );
    final text = Text.rich(TextSpan(
      children: NoticeHtml.spans(b.html, style, t.warning, keep: _recognizers.add, onLink: _openLink),
    ));
    switch (b.kind) {
      case 'li':
        return Padding(
          padding: const EdgeInsets.only(bottom: 6),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SizedBox(width: 18, child: Text('•', style: style.copyWith(color: t.primary))),
              Expanded(child: text),
            ],
          ),
        );
      case 'quote':
        return Container(
          margin: const EdgeInsets.only(bottom: 16),
          padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
          decoration: BoxDecoration(
            color: t.selected,
            borderRadius: BorderRadius.circular(8),
            border: Border(left: BorderSide(color: t.primary, width: 3)),
          ),
          child: text,
        );
      case 'h':
        return Padding(padding: const EdgeInsets.only(top: 6, bottom: 10), child: text);
      default:
        return Padding(padding: const EdgeInsets.only(bottom: 10), child: text);
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = PurchaseTokens.of(context);
    final button = _blocks.where((b) => b.kind == 'button').firstOrNull;
    // 第一次排版完：内容高度定了，看一下下面还有没有。
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _checkMore();
    });
    for (final r in _recognizers) {
      r.dispose();
    }
    _recognizers.clear();
    final list = ListView(
      controller: _scroll,
      shrinkWrap: true,
      padding: const EdgeInsets.fromLTRB(28, 20, 28, 12),
      children: [
        Row(
          children: [
            Text(widget.item.date, style: TextStyle(fontSize: 12, color: t.secondary.withValues(alpha: 0.7))),
            if (widget.item.important) ...[const SizedBox(width: 8), const _Pill('重要', alert: true)],
          ],
        ),
        Padding(
          padding: const EdgeInsets.only(top: 8, bottom: 14),
          child: Text(
            widget.item.title,
            style: TextStyle(fontSize: 20, fontWeight: FontWeight.w700, color: t.text, height: 1.3),
          ),
        ),
        for (final b in _blocks)
          if (b.kind != 'button') _block(b, t),
      ],
    );
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Flexible(
          child: Stack(
            children: [
              Scrollbar(controller: _scroll, child: list),
              // 长公告底部淡出（不写字，滚动条已经说明下面还有）
              if (_more)
                Positioned(
                  left: 0,
                  right: 0,
                  bottom: 0,
                  child: IgnorePointer(
                    child: Container(
                      height: 36,
                      decoration: BoxDecoration(
                        gradient: LinearGradient(
                          begin: Alignment.topCenter,
                          end: Alignment.bottomCenter,
                          colors: [t.raised.withValues(alpha: 0), t.raised],
                        ),
                      ),
                    ),
                  ),
                ),
            ],
          ),
        ),
        // 单独一行的链接 → 金色按钮，固定在卡片底部，长公告也看得到
        if (button != null)
          Padding(
            padding: const EdgeInsets.fromLTRB(28, 8, 28, 24),
            child: SizedBox(
              height: 46,
              child: FilledButton(
                style: FilledButton.styleFrom(
                  backgroundColor: t.primary,
                  foregroundColor: t.onPrimary,
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                  textStyle: Theme.of(context).textTheme.labelLarge?.copyWith(fontSize: 15, fontWeight: FontWeight.w700),
                ),
                onPressed: () => _openLink(button.href),
                child: Text('${button.html}  →', maxLines: 1, overflow: TextOverflow.ellipsis),
              ),
            ),
          )
        else
          const SizedBox(height: 10),
      ],
    );
  }
}
