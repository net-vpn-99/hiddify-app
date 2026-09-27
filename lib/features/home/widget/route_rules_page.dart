import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:hiddify/core/app_info/app_info_provider.dart';
import 'package:hiddify/core/preferences/general_preferences.dart';
import 'package:hiddify/features/connection/notifier/connection_notifier.dart';
import 'package:hiddify/features/connection/notifier/route_check_notifier.dart';
import 'package:hiddify/features/panel_auth/data/panel_api_base.dart';
import 'package:hiddify/features/panel_auth/notifier/panel_auth.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

/// 「查看分流规则」整页。文案、排版两端一致（VPN 仓库 docs/查看分流规则-说明页-手册.md）：
/// 一句话 → 国内 / 国外 / 线路 IP 固定 三块 → 实测 → 走错了反馈。
/// 界面里不出现「代理 / 全局 / 规则 / PAC」这类词（标题是用户定的入口名）。
class RouteRulesPage extends ConsumerStatefulWidget {
  const RouteRulesPage({super.key});

  @override
  ConsumerState<RouteRulesPage> createState() => _RouteRulesPageState();
}

class _RouteRulesPageState extends ConsumerState<RouteRulesPage> {
  final _nameCtl = TextEditingController();
  int _side = 0; // 0 未选 / 1 国内 / 2 国外
  String? _nameError;
  String? _sideError;
  String _sendState = ''; // '' / sending / done / failed / throttled
  DateTime? _lastSent;

  @override
  void initState() {
    super.initState();
    // 连着但还没测过（比如刚装好、换线后），打开时补测一次。
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final connected = ref.read(connectionNotifierProvider).valueOrNull?.isConnected ?? false;
      if (connected && ref.read(routeCheckProvider).status == 'idle') {
        ref.read(routeCheckProvider.notifier).check();
      }
    });
  }

  @override
  void dispose() {
    _nameCtl.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    final name = _nameCtl.text.trim();
    setState(() {
      _nameError = name.isEmpty ? '请填网站或 App 名称' : null;
      _sideError = _side == 0 ? '请选应该走哪边' : null;
    });
    if (_nameError != null || _sideError != null) return;
    if (_lastSent != null && DateTime.now().difference(_lastSent!) < const Duration(seconds: 30)) {
      setState(() => _sendState = 'throttled');
      return;
    }
    setState(() => _sendState = 'sending');

    final check = ref.read(routeCheckProvider);
    final line = ref.read(Preferences.lastNodeName);
    final version = ref.read(appInfoProvider).valueOrNull?.version ?? '';
    final message = '【走错了】${name.length > 100 ? name.substring(0, 100) : name} → 应该走${_side == 1 ? '国内' : '国外'}\n'
        '线路：${line.isEmpty ? '—' : line}　'
        '实测：国内=${check.domesticSummary.isEmpty ? '未测' : check.domesticSummary} '
        '国外=${check.foreignSummary.isEmpty ? '未测' : check.foreignSummary}\n'
        '平台：安卓 $version';
    try {
      final email = ref.read(panelAuthProvider).email ?? '';
      final dio = PanelApiBase.dio(userAgent: 'OneRay-Android-Feedback');
      await dio.post<dynamic>(
        '/api/v1/guest/gsl_diag/feedback',
        data: FormData.fromMap({
          'message': message,
          'version': version,
          'os': '${Platform.operatingSystem} / ${Platform.operatingSystemVersion}',
          'state': (ref.read(connectionNotifierProvider).valueOrNull?.isConnected ?? false) ? 'connected' : 'disconnected',
          'contact': '',
          'email': email,
        }),
      );
      if (!mounted) return;
      setState(() {
        _sendState = 'done';
        _lastSent = DateTime.now();
        _nameCtl.clear();
        _side = 0;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() => _sendState = 'failed');
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final text = theme.textTheme;
    final connected = ref.watch(connectionNotifierProvider).valueOrNull?.isConnected ?? false;
    final check = ref.watch(routeCheckProvider);
    final lineName = ref.watch(Preferences.lastNodeName);
    const green = Color(0xFF3FA372);

    Widget chip(String s) => Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(color: scheme.surfaceContainerHighest, borderRadius: BorderRadius.circular(6)),
      child: Text(s, style: text.bodySmall?.copyWith(color: scheme.onSurface)),
    );

    Widget block({
      required IconData icon,
      required String title,
      List<String> chips = const [],
      String etc = '',
      String body = '',
      required String verdict,
    }) {
      return Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 22, color: scheme.onSurfaceVariant),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title, style: text.titleSmall?.copyWith(fontWeight: FontWeight.w600)),
                const SizedBox(height: 8),
                if (chips.isNotEmpty)
                  Wrap(
                    spacing: 6,
                    runSpacing: 6,
                    crossAxisAlignment: WrapCrossAlignment.center,
                    children: [
                      ...chips.map(chip),
                      if (etc.isNotEmpty) Text(etc, style: text.bodySmall?.copyWith(color: scheme.outline)),
                    ],
                  ),
                if (body.isNotEmpty)
                  Text(body, style: text.bodyMedium?.copyWith(color: scheme.onSurfaceVariant, height: 1.5)),
                const SizedBox(height: 8),
                Text('✓ $verdict', style: text.bodySmall?.copyWith(color: green)),
              ],
            ),
          ),
        ],
      );
    }

    final warn = check.warning.isNotEmpty;
    Widget liveRow(String label, String value) => Padding(
      padding: const EdgeInsets.only(top: 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(width: 40, child: Text(label, style: text.bodySmall?.copyWith(color: scheme.onSurfaceVariant))),
          Expanded(
            child: Text(value.isEmpty ? '正在测…' : value, style: text.bodySmall?.copyWith(height: 1.5)),
          ),
        ],
      ),
    );

    final String? sendNote = switch (_sendState) {
      'done' => '收到，谢谢！我们核实后会调整。',
      'failed' => '没发出去，请稍后再试',
      'throttled' => '刚提交过，稍等一下',
      _ => null,
    };

    return Scaffold(
      appBar: AppBar(title: const Text('分流规则')),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(20, 8, 20, 24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // ① 一句话
              Text(
                '光速雷达在网卡层面做了智能分流：\n国内应用和网站用本地网络直连，国外网站和应用走光速雷达。',
                style: text.bodyMedium?.copyWith(fontWeight: FontWeight.w600, height: 1.6),
              ),
              const SizedBox(height: 4),
              Text('手机上所有 App 自动生效，不用一个个设置。', style: text.bodySmall?.copyWith(color: scheme.onSurfaceVariant)),
              const SizedBox(height: 20),

              // ② 三块
              block(
                icon: Icons.home_outlined,
                title: '国内 · 本地网络直连',
                chips: const ['微信', 'QQ', '支付宝', '淘宝', '抖音', 'B 站', '网银', '国内游戏'],
                etc: '等所有国内网站和 App',
                verdict: '网站看到的是你自己的 IP，QQ、微信不会提示异地登录；不计入套餐流量',
              ),
              const SizedBox(height: 20),
              block(
                icon: Icons.public,
                title: '国外 · 光速雷达',
                chips: const ['谷歌', 'YouTube', 'ChatGPT', 'Netflix', 'Telegram', 'X（推特）'],
                etc: '等所有国外网站和 App',
                verdict: lineName.isEmpty
                    ? '网站看到的是所用线路的地区，换线路会跟着变'
                    : '网站看到的是所用线路的地区（现在是$lineName），换线路会跟着变',
              ),
              const SizedBox(height: 20),
              block(
                icon: Icons.push_pin_outlined,
                title: '线路 IP 固定',
                body: '每条线路的 IP 是固定的，不会用着用着就变。只有线路被封时才会换新的，客户端会自动换上，不用你操作。',
                verdict: '常用的国外账号不会因为 IP 乱跳被要求反复验证',
              ),
              const SizedBox(height: 20),

              // ③ 实测
              Container(
                width: double.infinity,
                padding: const EdgeInsets.fromLTRB(14, 10, 8, 12),
                decoration: BoxDecoration(
                  color: warn ? scheme.errorContainer : green.withValues(alpha: 0.10),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Expanded(
                          child: Text(
                            '现在实际是这样',
                            style: text.titleSmall?.copyWith(
                              color: warn ? scheme.onErrorContainer : green,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ),
                        if (connected)
                          OutlinedButton(
                            style: OutlinedButton.styleFrom(minimumSize: const Size(64, 48)),
                            onPressed: check.status == 'running'
                                ? null
                                : () => ref.read(routeCheckProvider.notifier).check(),
                            child: Text(check.status == 'running' ? '正在测…' : '重测'),
                          ),
                      ],
                    ),
                    if (!connected)
                      Padding(
                        padding: const EdgeInsets.only(top: 6),
                        child: Text('连上后会在这里实时测给你看', style: text.bodySmall?.copyWith(color: scheme.outline)),
                      )
                    else ...[
                      liveRow('国内', check.domesticLine),
                      liveRow('国外', check.foreignLine),
                      if (check.status == 'done' && !check.listLoading)
                        Padding(
                          padding: const EdgeInsets.only(top: 8),
                          child: Text(
                            warn ? check.warning : '✓ 国内应用仍是你自己的 IP',
                            style: text.bodySmall?.copyWith(color: warn ? scheme.onErrorContainer : green),
                          ),
                        ),
                    ],
                  ],
                ),
              ),
              const SizedBox(height: 20),
              Divider(color: scheme.outlineVariant),
              const SizedBox(height: 12),

              // ④ 走错了？
              Text('发现有网站走错了？', style: text.titleSmall?.copyWith(fontWeight: FontWeight.w600)),
              const SizedBox(height: 2),
              Text('告诉我们，核实后会调整。', style: text.bodySmall?.copyWith(color: scheme.onSurfaceVariant)),
              const SizedBox(height: 12),
              TextField(
                controller: _nameCtl,
                maxLength: 100,
                onChanged: (_) {
                  if (_nameError != null) setState(() => _nameError = null);
                },
                decoration: InputDecoration(
                  hintText: '网站或 App 名称，比如 某某银行',
                  errorText: _nameError,
                  counterText: '',
                  border: const OutlineInputBorder(),
                  isDense: true,
                ),
              ),
              const SizedBox(height: 10),
              SizedBox(
                width: double.infinity,
                child: SegmentedButton<int>(
                  segments: const [
                    ButtonSegment(value: 1, label: Text('应该走国内')),
                    ButtonSegment(value: 2, label: Text('应该走国外')),
                  ],
                  emptySelectionAllowed: true,
                  showSelectedIcon: false,
                  selected: _side == 0 ? <int>{} : {_side},
                  onSelectionChanged: (s) => setState(() {
                    _side = s.isEmpty ? 0 : s.first;
                    _sideError = null;
                  }),
                ),
              ),
              if (_sideError != null)
                Padding(
                  padding: const EdgeInsets.only(top: 6, left: 4),
                  child: Text(_sideError!, style: text.bodySmall?.copyWith(color: scheme.error)),
                ),
              const SizedBox(height: 12),
              SizedBox(
                width: double.infinity,
                height: 48,
                child: FilledButton(
                  onPressed: _sendState == 'sending' ? null : _submit,
                  child: Text(_sendState == 'sending' ? '提交中…' : '提交'),
                ),
              ),
              if (sendNote != null)
                Padding(
                  padding: const EdgeInsets.only(top: 10),
                  child: Text(
                    sendNote,
                    style: text.bodySmall?.copyWith(color: _sendState == 'done' ? green : scheme.error),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}
