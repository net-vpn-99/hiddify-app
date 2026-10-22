import 'package:flutter/material.dart';
import 'package:hiddify/core/model/constants.dart';
import 'package:hiddify/core/model/remote_site_config.dart';
import 'package:hiddify/core/theme/oneray_tokens.dart';
import 'package:hiddify/features/connection/widget/connect_check_card.dart';
import 'package:hiddify/features/settings/overview/settings_page.dart';
import 'package:hiddify/utils/utils.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

/// 「我的 → 帮助与诊断」：常见问题 + 连接检查（10-22 起「连接诊断」「初始化本地网络」都并进连接检查，
/// 结果页底部还留着初始化 / 导出诊断，docs/计划/连接检查.md 第八节）。
class HelpCenterPage extends ConsumerWidget {
  const HelpCenterPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
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
              MenuRow(title: '连接检查', hint: '帮我查一查', onTap: () => showConnectCheck(context, ref)),
            ],
          ),
        ],
      ),
    );
  }
}
