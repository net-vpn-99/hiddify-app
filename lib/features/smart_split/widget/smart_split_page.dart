import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:hiddify/core/directories/directories_provider.dart';
import 'package:hiddify/core/preferences/general_preferences.dart';
import 'package:hiddify/core/theme/oneray_tokens.dart';
import 'package:hiddify/features/common/guide_card.dart';
import 'package:hiddify/features/connection/notifier/connection_notifier.dart';
import 'package:hiddify/features/connection/notifier/route_check_notifier.dart';
import 'package:hiddify/features/smart_split/data/split_diag.dart';
import 'package:hiddify/features/smart_split/model/split_choices.dart';
import 'package:hiddify/features/smart_split/notifier/smart_split_controller.dart';
import 'package:hiddify/features/smart_split/notifier/smart_split_notifier.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

/// 智能分流（VPN 仓库 docs/计划/智能分流-自己改网站.md 四，样稿 docs/计划/智能分流-样稿/，跟 Windows SmartSplitPanel.qml 同一套）：
/// 现在的线路 → 分流采集（网站一块、App 一块，不能改的合成最下面一行）→ 我改过的 → 收起的「默认怎么分？」。
/// 没连上：只有一张说明卡 + 只能看的「我改过的」。改规则要重开隧道，这段时间页面停在原地。
/// 界面里不出现「代理 / 全局 / 规则 / PAC」这类词。
class SmartSplitPage extends ConsumerStatefulWidget {
  const SmartSplitPage({super.key});

  @override
  ConsumerState<SmartSplitPage> createState() => _SmartSplitPageState();
}

class _SmartSplitPageState extends ConsumerState<SmartSplitPage> {
  @override
  void initState() {
    super.initState();
    // 连着但还没测过（比如刚装好、换线后），打开时补测一次。
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final connected = ref.read(connectionNotifierProvider).valueOrNull?.isConnected ?? false;
      if (connected && ref.read(routeCheckProvider).status == 'idle') ref.read(routeCheckProvider.notifier).check();
    });
  }

  @override
  Widget build(BuildContext context) => SmartSplitView(
    connected: ref.watch(connectionNotifierProvider).valueOrNull?.isConnected ?? false,
    state: ref.watch(smartSplitProvider),
    check: ref.watch(routeCheckProvider),
    lineName: ref.watch(Preferences.lastNodeName),
    actions: ref.read(smartSplitProvider.notifier),
    onRecheck: () => ref.read(routeCheckProvider.notifier).check(),
    readDiag: () async {
      try {
        final dirs = await ref.read(appDirectoriesProvider.future);
        return readSplitDiag(dirs.workingDir);
      } catch (e) {
        return '读不了：$e';
      }
    },
  );
}

/// 页面本体（不碰 provider，截图测试直接喂数据）。
class SmartSplitView extends StatefulWidget {
  const SmartSplitView({
    super.key,
    required this.connected,
    required this.state,
    required this.check,
    required this.lineName,
    required this.actions,
    required this.onRecheck,
    this.readDiag,
  });

  final bool connected;
  final SmartSplitState state;
  final RouteCheckState check;
  final String lineName;
  final SplitActions actions;
  final VoidCallback onRecheck;

  /// 点「没开出来？看这次实际怎样」时读规则文件和连接日志。截图测试不传。
  final Future<String> Function()? readDiag;

  @override
  State<SmartSplitView> createState() => _SmartSplitViewState();
}

class _SmartSplitViewState extends State<SmartSplitView> {
  bool _explainOpen = false;
  bool _fixedOpen = false;
  final _urlsOpen = <String>{};

  @override
  Widget build(BuildContext context) {
    final tk = OneRayTokens.of(context);
    final text = Theme.of(context).textTheme;
    final connected = widget.connected || widget.state.holding;
    final s = widget.state;
    final n = widget.actions;

    TextStyle body([Color? c]) => text.bodySmall!.copyWith(color: c ?? tk.sub, height: 1.45, fontSize: 13);
    TextStyle small([Color? c]) => text.bodySmall!.copyWith(color: c ?? tk.sub, fontSize: 12);
    TextStyle title([Color? c]) => text.titleSmall!.copyWith(color: c ?? tk.text, fontWeight: FontWeight.w600);

    return Scaffold(
      backgroundColor: tk.bg,
      appBar: AppBar(title: const Text('智能分流')),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.fromLTRB(16, 4, 16, 28),
          children: [
            Text('国内网站走本地网络，国外网站走光速雷达。可以根据自己的实际情况自己选。', style: body()),
            const SizedBox(height: 18),
            if (!connected) ...[
              _NotConnectedCard(hasMine: s.mine.isNotEmpty),
              const SizedBox(height: 22),
            ] else ...[
              if (!s.collecting) ...[_LiveCard(check: widget.check, onRecheck: widget.onRecheck), const SizedBox(height: 18)],
              _collectCard(context, tk, s, n, body, small, title),
              const SizedBox(height: 22),
            ],
            if (s.mine.isNotEmpty) ...[_mine(context, tk, s, n, connected, body, small, title), const SizedBox(height: 22)],
            _explain(tk, body, title),
          ],
        ),
      ),
    );
  }

  // ② 分流采集
  Widget _collectCard(
    BuildContext context,
    OneRayTokens tk,
    SmartSplitState s,
    SplitActions n,
    TextStyle Function([Color?]) body,
    TextStyle Function([Color?]) small,
    TextStyle Function([Color?]) title,
  ) {
    Widget step(String no, String t) => Padding(
      padding: const EdgeInsets.only(top: 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 20,
            height: 20,
            alignment: Alignment.center,
            decoration: BoxDecoration(color: tk.panel, shape: BoxShape.circle),
            child: Text(no, style: small().copyWith(fontWeight: FontWeight.w600)),
          ),
          const SizedBox(width: 8),
          Expanded(child: Text(t, style: body(tk.text))),
        ],
      ),
    );

    final sites = s.pickable.where((r) => r.kind == 'site').toList();
    final apps = s.pickable.where((r) => r.kind != 'site').toList();
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: tk.card,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: s.collecting ? tk.acc : tk.ring),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (!s.collecting) ...[
            // 说明只留三步（10-25 TEST5 运营：解释太多，要一看就懂）
            Text('分流采集', style: title()),
            const SizedBox(height: 4),
            step('1', '点「开始采集」'),
            step('2', '打开那个网站或 App（网页刷新一下）'),
            step('3', '回来选走哪边'),
            const SizedBox(height: 14),
            SizedBox(
              height: 44,
              child: FilledButton(
                style: FilledButton.styleFrom(backgroundColor: tk.acc, foregroundColor: tk.accInk),
                onPressed: n.startCollect,
                child: const Text('开始采集'),
              ),
            ),
          ] else ...[
            Row(
              children: [
                Container(width: 8, height: 8, decoration: BoxDecoration(color: tk.acc, shape: BoxShape.circle)),
                const SizedBox(width: 8),
                Expanded(child: Text('正在采集…', style: title())),
                OutlinedButton(
                  style: OutlinedButton.styleFrom(minimumSize: const Size(84, 40)),
                  onPressed: n.stopCollect,
                  child: const Text('停止采集'),
                ),
              ],
            ),
            const SizedBox(height: 4),
            Text('打开那个网站或 App（网页刷新一下），再回到这里', style: body()),
            if (s.pickable.isEmpty && s.fixed.isEmpty)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 14),
                child: Text('还没有。打开以后这里会马上出现。', textAlign: TextAlign.center, style: body(tk.dim)),
              ),
            if (sites.isNotEmpty) _section('网站', sites, tk, s, n, body, small),
            if (apps.isNotEmpty) _section('App', apps, tk, s, n, body, small),
            if (s.fixed.isNotEmpty) _fixed(context, tk, s, body, small),
          ],
        ],
      ),
    );
  }

  // 能选的：网站一块、App 一块，各自一个灰底框、标题在框外
  Widget _section(
    String name,
    List<SplitRow> rows,
    OneRayTokens tk,
    SmartSplitState s,
    SplitActions n,
    TextStyle Function([Color?]) body,
    TextStyle Function([Color?]) small,
  ) {
    return Padding(
      padding: const EdgeInsets.only(top: 14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text('$name · ${rows.length} 个', style: small()),
          const SizedBox(height: 8),
          Container(
            decoration: BoxDecoration(color: tk.panel, borderRadius: BorderRadius.circular(10)),
            child: Column(
              children: [
                for (var i = 0; i < rows.length; i++) ...[
                  if (i > 0) Divider(height: 1, color: tk.ring, indent: 12, endIndent: 12),
                  if (rows[i].kind == 'site') _siteRow(rows[i], tk, s, n, body, small) else _appRow(rows[i], tk, s, n, body, small),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _note(SplitRow r, OneRayTokens tk, SmartSplitState s, SplitActions n, TextStyle Function([Color?]) body) {
    final note = s.rowNote[r.key] ?? '';
    final site = r.kind == 'site';
    final going = s.applying[r.key];
    final (String msg, Color color, bool retry) = switch (note) {
      'reconnecting' => (
          site
              ? (going == 'direct'
                  ? '正在让这个网站走本地。'
                  : going == 'proxy'
                      ? '正在让这个网站走光速雷达。'
                      : '正在改回。')
              : (going == 'direct' ? '正在让这个 App 走本地。' : '正在改回。'),
          tk.sub,
          false,
        ),
      'done' => (site ? '好了。回浏览器把那个网页重新打开。' : '好了。重新打开那个 App。', tk.ok, false),
      'failed' => ('没改成，点这里再试', tk.fault, true),
      'full' => ('最多改 50 个，先在「我改过的」里改回几个', tk.fault, false),
      _ => ('', tk.sub, false),
    };
    if (msg.isEmpty) return const SizedBox.shrink();
    final showDiag = widget.readDiag != null && (note == 'done' || note == 'failed');
    return Padding(
      padding: const EdgeInsets.only(left: 44, top: 2, bottom: 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          GestureDetector(
            onTap: retry
                ? () {
                    final again = s.retryAs[r.key];
                    if (again == 'reset') {
                      n.resetOne(r.key);
                    } else {
                      n.choose(r.key, again ?? r.now);
                    }
                  }
                : null,
            child: Row(
              children: [
                if (note == 'done') ...[Icon(Icons.check, size: 14, color: tk.ok), const SizedBox(width: 4)],
                Expanded(child: Text(msg, style: body(color))),
              ],
            ),
          ),
          if (showDiag)
            GestureDetector(
              onTap: _showDiag,
              child: Padding(
                padding: const EdgeInsets.only(top: 2),
                child: Text('没开出来？看这次实际怎样', style: body(tk.acc)),
              ),
            ),
        ],
      ),
    );
  }

  Future<void> _showDiag() async {
    final read = widget.readDiag;
    if (read == null) return;
    final text = await read();
    if (!mounted) return;
    await showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('这次实际怎样'),
        content: SingleChildScrollView(child: SelectableText(text)),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('关闭')),
          FilledButton(
            onPressed: () async {
              await Clipboard.setData(ClipboardData(text: text));
              if (ctx.mounted) Navigator.pop(ctx);
            },
            child: const Text('复制'),
          ),
        ],
      ),
    );
  }

  // 网站：名字（下面「+N 个关联网址」）+ 右边两个选项，亮着的就是现在走的
  Widget _siteRow(
    SplitRow r,
    OneRayTokens tk,
    SmartSplitState s,
    SplitActions n,
    TextStyle Function([Color?]) body,
    TextStyle Function([Color?]) small,
  ) {
    final domains = r.thing.domains;
    final hasUrls = r.key.startsWith('site:') && domains.length > 1;
    final open = _urlsOpen.contains(r.key);
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              _Avatar(label: r.name, icon: null, app: false),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(r.name, maxLines: 1, overflow: TextOverflow.ellipsis, style: body(tk.text).copyWith(fontSize: 14)),
                    if (hasUrls)
                      GestureDetector(
                        onTap: () => setState(() => open ? _urlsOpen.remove(r.key) : _urlsOpen.add(r.key)),
                        child: Padding(
                          padding: const EdgeInsets.symmetric(vertical: 2),
                          child: Text(open ? '收起关联网址' : '+${domains.length - 1} 个关联网址', style: small()),
                        ),
                      ),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              if (s.rowNote[r.key] == 'reconnecting')
                const _Changing()
              else
                _TwoWay(now: r.now, onPick: (v) => n.choose(r.key, v)),
            ],
          ),
          _note(r, tk, s, n, body),
          // 关联网址（点「+N 个关联网址」才展开）。给懂的人用，可以取消勾选。
          if (open)
            Padding(
              padding: const EdgeInsets.only(left: 40, top: 4),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('打开它时一起连的，会跟着一起改', style: small()),
                  for (final d in domains)
                    InkWell(
                      onTap: d == r.thing.host
                          ? null
                          : () => n.setDomainIncluded(r.key, d, included: r.excluded.contains(d)),
                      child: Padding(
                        padding: const EdgeInsets.symmetric(vertical: 6),
                        child: Row(
                          children: [
                            Icon(
                              r.excluded.contains(d) ? Icons.check_box_outline_blank : Icons.check_box,
                              size: 18,
                              color: r.excluded.contains(d) ? tk.line : tk.acc,
                            ),
                            const SizedBox(width: 8),
                            Text(d, style: body(r.excluded.contains(d) ? tk.dim : tk.text)),
                          ],
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

  // App：开着 = 整个走本地；关着 = 跟别的 App 一样国内走本地、国外走光速雷达
  Widget _appRow(
    SplitRow r,
    OneRayTokens tk,
    SmartSplitState s,
    SplitActions n,
    TextStyle Function([Color?]) body,
    TextStyle Function([Color?]) small,
  ) {
    final on = r.kind == 'downloader' ? r.choice != 'split' : r.choice == 'direct';
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 8, 4, 6),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              _Avatar(label: r.name, icon: n.icons[r.thing.pkg], app: true),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(r.name, maxLines: 1, overflow: TextOverflow.ellipsis, style: body(tk.text).copyWith(fontSize: 14)),
                    Text(on ? '整个走本地' : '国内走本地，国外走光速雷达', style: small()),
                  ],
                ),
              ),
              if (s.rowNote[r.key] == 'reconnecting')
                const _Changing()
              else
                Switch(
                  value: on,
                  activeTrackColor: tk.acc,
                  onChanged: (v) => n.choose(r.key, v ? 'direct' : 'split'),
                ),
            ],
          ),
          _note(r, tk, s, n, body),
        ],
      ),
    );
  }

  // 不能改的：合成一行「还有 N 个不能改：谷歌、微信…」，点开才一行一个
  Widget _fixed(
    BuildContext context,
    OneRayTokens tk,
    SmartSplitState s,
    TextStyle Function([Color?]) body,
    TextStyle Function([Color?]) small,
  ) {
    return Padding(
      padding: const EdgeInsets.only(top: 14),
      child: Container(
        decoration: BoxDecoration(color: tk.panel, borderRadius: BorderRadius.circular(10)),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            InkWell(
              borderRadius: BorderRadius.circular(10),
              onTap: () => setState(() => _fixedOpen = !_fixedOpen),
              child: SizedBox(
                height: 44,
                child: Row(
                  children: [
                    const SizedBox(width: 12),
                    Icon(Icons.lock_outline, size: 16, color: tk.dim),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text(
                        '还有 ${s.fixed.length} 个不能改：${s.fixed.map((r) => r.name).join('、')}',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: body(),
                      ),
                    ),
                    Icon(_fixedOpen ? Icons.expand_less : Icons.expand_more, size: 18, color: tk.sub),
                    const SizedBox(width: 10),
                  ],
                ),
              ),
            ),
            if (_fixedOpen) ...[
              for (final r in s.fixed) ...[
                Divider(height: 1, color: tk.ring, indent: 38),
                Padding(
                  padding: const EdgeInsets.fromLTRB(38, 10, 12, 10),
                  child: Row(
                    children: [
                      Expanded(child: Text(r.name, maxLines: 1, overflow: TextOverflow.ellipsis, style: body(tk.text))),
                      Text(r.thing.lockWhy, style: body()),
                    ],
                  ),
                ),
              ],
              Divider(height: 1, color: tk.ring, indent: 38),
              // 「必须」万一认错了：走联系客服，输入框里先填「智能分流：」，他自己写是哪个（谷歌、银行这些定好的不替他写）
              InkWell(
                onTap: () => openSupportWithText(context, '智能分流：'),
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(38, 12, 12, 12),
                  child: Text('有打不开的？告诉我们', style: body()),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  // ③ 我改过的（一个都没有就不显示；没连上时只能看）
  Widget _mine(
    BuildContext context,
    OneRayTokens tk,
    SmartSplitState s,
    SplitActions n,
    bool connected,
    TextStyle Function([Color?]) body,
    TextStyle Function([Color?]) small,
    TextStyle Function([Color?]) title,
  ) {
    String route(SplitChoice c) => c.kind == 'site'
        ? (c.choice == 'direct' ? '走本地' : '走光速雷达')
        : (c.choice == 'direct' ? '整个走本地' : '国内外分开走');
    String where(SplitChoice c) =>
        c.kind == 'site' ? '网站 · ${s.loggedIn && c.synced ? '账号里' : '这台手机'}' : 'App · 这台手机';
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Expanded(child: Text('我改过的', style: title())),
            if (connected)
              TextButton(
                style: TextButton.styleFrom(foregroundColor: tk.text),
                onPressed: () => _confirmResetAll(context, s, n),
                child: const Text('全部改回默认'),
              ),
          ],
        ),
        Text('网站存在账号里，换设备也生效；App 只在这台手机生效。我们只知道你改了什么、选了哪边，不知道你看了什么。', style: small()),
        const SizedBox(height: 10),
        Container(
          decoration: BoxDecoration(
            color: tk.card,
            borderRadius: BorderRadius.circular(10),
            border: Border.all(color: tk.ring),
          ),
          child: Column(
            children: [
              for (var i = 0; i < s.mine.length; i++) ...[
                if (i > 0) Divider(height: 1, color: tk.ring, indent: 54),
                Padding(
                  padding: EdgeInsets.fromLTRB(12, 10, connected ? 4 : 16, 10),
                  child: Row(
                    children: [
                      _Avatar(label: s.mine[i].name, icon: n.icons[s.mine[i].pkg], app: s.mine[i].kind != 'site', onCard: true),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(s.mine[i].name, maxLines: 1, overflow: TextOverflow.ellipsis, style: body(tk.text)),
                            Text(where(s.mine[i]), style: small()),
                            if (s.mineNote[s.mine[i].key] == 'retry')
                              GestureDetector(
                                onTap: () => n.retrySync(s.mine[i].key),
                                child: Text('没存上，点一下重试', style: small(tk.fault)),
                              ),
                            if (s.rowNote[s.mine[i].key] == 'failed')
                              Text('没改成', style: small(tk.fault)),
                          ],
                        ),
                      ),
                      if (s.applying.containsKey(s.mine[i].key))
                        Text('正在改', style: body(tk.sub).copyWith(fontWeight: FontWeight.w600))
                      else ...[
                        Text(route(s.mine[i]), style: body(connected ? tk.text : tk.sub).copyWith(fontWeight: FontWeight.w600)),
                        if (connected)
                          TextButton(
                            style: TextButton.styleFrom(foregroundColor: tk.sub),
                            onPressed: () => n.resetOne(s.mine[i].key),
                            child: const Text('改回默认'),
                          ),
                      ],
                    ],
                  ),
                ),
              ],
            ],
          ),
        ),
      ],
    );
  }

  Future<void> _confirmResetAll(BuildContext context, SmartSplitState s, SplitActions n) async {
    final hasAccount = s.mine.any((c) => c.kind == 'site' && s.loggedIn && c.synced);
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('把 ${s.mine.length} 个都改回默认？'),
        content: Text(hasAccount ? '网站在你登录的所有设备上都会改回，想再改要重新采集。' : '改回以后按我们的规则走，想再改要重新采集。'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('取消')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('改回默认')),
        ],
      ),
    );
    if (ok ?? false) await n.resetAll();
  }

  // ④ 默认怎么分（收起）
  Widget _explain(OneRayTokens tk, TextStyle Function([Color?]) body, TextStyle Function([Color?]) title) {
    final line = widget.lineName;
    Widget row(String what, String how) => Padding(
      padding: const EdgeInsets.only(top: 12),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(width: 104, child: Text(what, style: body(tk.text).copyWith(fontWeight: FontWeight.w600))),
          Expanded(child: Text(how, style: body())),
        ],
      ),
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Divider(height: 1, color: tk.ring),
        InkWell(
          onTap: () => setState(() => _explainOpen = !_explainOpen),
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 12),
            child: Row(
              children: [
                Expanded(child: Text('默认怎么分？', style: body().copyWith(fontSize: 14))),
                Icon(_explainOpen ? Icons.expand_less : Icons.expand_more, size: 20, color: tk.sub),
              ],
            ),
          ),
        ),
        if (_explainOpen) ...[
          row('国内网站和 App', '走本地网络。网站看到的是你自己的 IP，不计套餐流量。'),
          row('国外网站和 App', line.isEmpty ? '走光速雷达。网站看到的是线路所在地。' : '走光速雷达。网站看到的是线路所在地（现在是$line）。'),
          row('BT、迅雷下载', '走本地网络，不计套餐流量。'),
          Padding(padding: const EdgeInsets.only(top: 14), child: Text('想换个走法？用上面的「分流采集」自己选。', style: body())),
        ],
      ],
    );
  }
}

/// 没连上：一张说明卡。
class _NotConnectedCard extends StatelessWidget {
  const _NotConnectedCard({required this.hasMine});

  final bool hasMine;

  @override
  Widget build(BuildContext context) {
    final tk = OneRayTokens.of(context);
    final text = Theme.of(context).textTheme;
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(color: tk.accSoft, borderRadius: BorderRadius.circular(12)),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(Icons.wifi, size: 20, color: tk.sub),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('还没连上光速雷达', style: text.titleSmall!.copyWith(color: tk.text, fontWeight: FontWeight.w600)),
                const SizedBox(height: 4),
                Text(
                  hasMine ? '连上以后才能采集和修改。下面是你改过的，连上就生效。' : '连上以后才能采集和修改。',
                  style: text.bodySmall!.copyWith(color: tk.sub, height: 1.45, fontSize: 13),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// ① 现在的线路（平时才有；采集时收起）。
class _LiveCard extends StatelessWidget {
  const _LiveCard({required this.check, required this.onRecheck});

  final RouteCheckState check;
  final VoidCallback onRecheck;

  @override
  Widget build(BuildContext context) {
    final tk = OneRayTokens.of(context);
    final text = Theme.of(context).textTheme;
    final warn = check.warning.isNotEmpty;
    Widget line(String label, String value) => Padding(
      padding: const EdgeInsets.only(top: 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(width: 40, child: Text(label, style: text.bodySmall!.copyWith(color: tk.sub))),
          Expanded(child: Text(value.isEmpty ? '正在测…' : value, style: text.bodySmall!.copyWith(color: tk.text, height: 1.45))),
        ],
      ),
    );
    return Container(
      padding: const EdgeInsets.fromLTRB(14, 8, 8, 12),
      decoration: BoxDecoration(color: warn ? tk.faultSoft : tk.accSoft, borderRadius: BorderRadius.circular(10)),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  '现在的线路',
                  style: text.titleSmall!.copyWith(color: warn ? tk.fault : tk.ok, fontWeight: FontWeight.w600),
                ),
              ),
              TextButton(
                style: TextButton.styleFrom(foregroundColor: tk.text),
                onPressed: check.status == 'running' ? null : onRecheck,
                child: Text(check.status == 'running' ? '正在测…' : '重测'),
              ),
            ],
          ),
          line('国内', check.domesticLine),
          line('国外', check.foreignLine),
          if (warn && check.status == 'done')
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: Text(check.warning, style: text.bodySmall!.copyWith(color: tk.fault)),
            ),
        ],
      ),
    );
  }
}

/// 网站 = 圆底地球；App = 它自己的图标（取不到退回圆角方块首字）。
class _Avatar extends StatelessWidget {
  const _Avatar({required this.label, required this.icon, required this.app, this.onCard = false});

  final String label;
  final Uint8List? icon;
  final bool app;

  /// 放在白卡片上（「我改过的」）：底色用浅灰才看得出
  final bool onCard;

  @override
  Widget build(BuildContext context) {
    final tk = OneRayTokens.of(context);
    final png = icon;
    if (app && png != null && png.isNotEmpty) {
      return ClipRRect(
        borderRadius: BorderRadius.circular(8),
        child: Image.memory(png, width: 30, height: 30, gaplessPlayback: true),
      );
    }
    return Container(
      width: 30,
      height: 30,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: onCard ? tk.panel : tk.card,
        borderRadius: BorderRadius.circular(app ? 8 : 15),
      ),
      child: app
          ? Text(label.isEmpty ? '?' : label.characters.first.toUpperCase(), style: TextStyle(color: tk.sub, fontSize: 12))
          : Icon(Icons.public, size: 18, color: tk.sub),
    );
  }
}

/// 正在重开隧道。先别亮成新的那边。
class _Changing extends StatelessWidget {
  const _Changing();

  @override
  Widget build(BuildContext context) {
    final tk = OneRayTokens.of(context);
    return Container(
      height: 32,
      padding: const EdgeInsets.symmetric(horizontal: 10),
      alignment: Alignment.center,
      decoration: BoxDecoration(color: tk.ring, borderRadius: BorderRadius.circular(9)),
      child: Text('正在改', style: TextStyle(fontSize: 12, color: tk.sub)),
    );
  }
}

/// 网站那行右边的两个选项：亮着的就是现在走的（橙红只表示选中）。
class _TwoWay extends StatelessWidget {
  const _TwoWay({required this.now, required this.onPick});

  final String now;
  final void Function(String)? onPick;

  @override
  Widget build(BuildContext context) {
    final tk = OneRayTokens.of(context);
    Widget opt(String value, String label) {
      final on = now == value;
      return GestureDetector(
        onTap: on || onPick == null ? null : () => onPick!(value),
        child: Container(
          height: 32,
          padding: const EdgeInsets.symmetric(horizontal: 10),
          alignment: Alignment.center,
          decoration: BoxDecoration(color: on ? tk.acc : Colors.transparent, borderRadius: BorderRadius.circular(7)),
          child: Text(
            label,
            style: TextStyle(fontSize: 12, color: on ? tk.accInk : tk.sub, fontWeight: on ? FontWeight.w600 : FontWeight.w400),
          ),
        ),
      );
    }

    return Container(
      padding: const EdgeInsets.all(2),
      decoration: BoxDecoration(color: tk.ring, borderRadius: BorderRadius.circular(9)),
      child: Row(mainAxisSize: MainAxisSize.min, children: [opt('direct', '走本地'), opt('proxy', '走光速雷达')]),
    );
  }
}
