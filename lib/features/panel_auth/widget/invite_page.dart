import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_hooks/flutter_hooks.dart';
import 'package:hiddify/features/panel_auth/notifier/panel_auth.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:share_plus/share_plus.dart';

class InvitePage extends HookConsumerWidget {
  const InvitePage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final data = useState<({String code, String link})?>(null);
    final loading = useState(true);

    useEffect(() {
      () async {
        data.value = await ref.read(panelAuthProvider.notifier).getInvite();
        loading.value = false;
      }();
      return null;
    }, const []);

    final d = data.value;
    final shareText = d == null
        ? ''
        : '我在用「光速」，速度快、YouTube 4K 不卡。\n用我的链接注册，咱俩各得流量：\n${d.link}';

    return Scaffold(
      appBar: AppBar(title: const Text('邀请好友')),
      body: loading.value
          ? const Center(child: CircularProgressIndicator())
          : d == null
              ? const Center(child: Text('拉取邀请码失败，返回重试'))
              : ListView(
                  padding: const EdgeInsets.all(24),
                  children: [
                    Text(
                      '好友通过你的链接注册，你和好友各得奖励；好友付费你再得返利。',
                      style: theme.textTheme.bodyMedium?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                    ),
                    const SizedBox(height: 24),
                    Center(
                      child: Container(
                        padding: const EdgeInsets.all(12),
                        decoration: BoxDecoration(
                          color: Colors.white,
                          borderRadius: BorderRadius.circular(12),
                        ),
                        child: QrImageView(data: d.link, size: 200, backgroundColor: Colors.white),
                      ),
                    ),
                    const SizedBox(height: 20),
                    Center(
                      child: Column(
                        children: [
                          Text('你的邀请码', style: theme.textTheme.bodySmall),
                          const SizedBox(height: 4),
                          Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              SelectableText(
                                d.code,
                                style: theme.textTheme.headlineSmall?.copyWith(
                                  fontWeight: FontWeight.bold,
                                  letterSpacing: 2,
                                ),
                              ),
                              IconButton(
                                icon: const Icon(Icons.copy, size: 18),
                                onPressed: () {
                                  Clipboard.setData(ClipboardData(text: d.code));
                                  ScaffoldMessenger.of(context)
                                      .showSnackBar(const SnackBar(content: Text('邀请码已复制')));
                                },
                              ),
                            ],
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 24),
                    FilledButton.icon(
                      icon: const Icon(Icons.share),
                      label: const Text('分享邀请链接与文案'),
                      onPressed: () => Share.share(shareText),
                    ),
                    const SizedBox(height: 8),
                    OutlinedButton.icon(
                      icon: const Icon(Icons.link),
                      label: const Text('复制邀请链接'),
                      onPressed: () {
                        Clipboard.setData(ClipboardData(text: d.link));
                        ScaffoldMessenger.of(context)
                            .showSnackBar(const SnackBar(content: Text('邀请链接已复制')));
                      },
                    ),
                  ],
                ),
    );
  }
}
