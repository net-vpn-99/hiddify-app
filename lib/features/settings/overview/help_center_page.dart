import 'package:flutter/material.dart';
import 'package:hiddify/core/model/constants.dart';
import 'package:hiddify/core/model/remote_site_config.dart';
import 'package:hiddify/core/theme/oneray_tokens.dart';
import 'package:hiddify/features/connection/model/connection_status.dart';
import 'package:hiddify/features/connection/notifier/connection_notifier.dart';
import 'package:hiddify/features/connection/notifier/local_repair.dart';
import 'package:hiddify/features/diagnostic/diag_tile.dart';
import 'package:hiddify/features/settings/overview/settings_page.dart';
import 'package:hiddify/utils/utils.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

/// 「我的 → 帮助与诊断」：遇到问题时用的三样（10-18 从「我的」一级挪进来，那一页太杂）。
class HelpCenterPage extends StatelessWidget {
  const HelpCenterPage({super.key});

  @override
  Widget build(BuildContext context) {
    final tk = OneRayTokens.of(context);
    return Scaffold(
      backgroundColor: tk.bg,
      appBar: AppBar(title: const Text('帮助与诊断'), backgroundColor: tk.bg, surfaceTintColor: Colors.transparent),
      body: ListView(
        children: [
          MenuGroup(
            children: [
              MenuRow(
                title: '常见问题',
                onTap: () async {
                  await RemoteSiteConfig.ensureLoaded();
                  await UriUtils.tryLaunch(Uri.parse(RemoteSiteConfig.helpUrlOr(Constants.faqUrl)));
                },
              ),
              DiagTile(builder: (context, busy, run) => MenuRow(title: '连接诊断', busy: busy, onTap: run)),
              const _LocalInitRow(),
            ],
          ),
        ],
      ),
    );
  }
}

/// 「初始化本地网络」（两端同名，Windows 在「更多」里）：一直在，他自己找过来点的不会误会。
/// 做什么见 local_repair.dart；不弹确认框，做完一句话说做了哪几步。
class _LocalInitRow extends ConsumerStatefulWidget {
  const _LocalInitRow();

  @override
  ConsumerState<_LocalInitRow> createState() => _LocalInitRowState();
}

class _LocalInitRowState extends ConsumerState<_LocalInitRow> {
  bool _busy = false;

  Future<void> _run() async {
    final s = ref.read(connectionNotifierProvider).valueOrNull;
    final wasUp = s is Connected || s is Connecting;
    setState(() => _busy = true);
    final done = await ref.read(localRepairProvider).initialize();
    if (!mounted) return;
    setState(() => _busy = false);
    if (done.isEmpty) return;
    final messenger = ScaffoldMessenger.of(context);
    messenger.hideCurrentSnackBar();
    messenger.showSnackBar(
      SnackBar(content: Text('已$done${wasUp ? '，正在重新连接' : ''}')),
    );
  }

  @override
  Widget build(BuildContext context) {
    return MenuRow(
      title: '初始化本地网络',
      busy: _busy,
      onTap: _run,
    );
  }
}
