import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_hooks/flutter_hooks.dart';
import 'package:hiddify/features/panel_auth/notifier/panel_auth.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

/// 免注册号的「钥匙」：账号编号 + 密码。
///
/// 这是「不注册也能用」这条线上唯一一次**必须让用户动手**的地方 —— 在它之前账号只认
/// 这台手机，抄走这两行之后换手机、重装都能登回来。
///
/// ⚠️ 密码服务端**只发一次**（它那边只存哈希）。所以：
///  - 点外面关不掉，只能按「我抄好了」或「以后再说」；
///  - 「以后再说」不删本地那份，「我的」页会一直挂红点，随时能再打开；
///  - 说实话那句「丢了谁也找不回」必须留在这一屏。
Future<void> showAccountKeyDialog(BuildContext context, WidgetRef ref) async {
  final auth = ref.read(panelAuthProvider);
  final no = auth.accountNo ?? '';
  final pw = auth.guestPassword ?? '';
  if (no.isEmpty || pw.isEmpty) return;

  await showDialog<void>(
    context: context,
    barrierDismissible: false,
    builder: (ctx) => _AccountKeyDialog(accountNo: no, password: pw),
  );
}

class _AccountKeyDialog extends HookConsumerWidget {
  const _AccountKeyDialog({required this.accountNo, required this.password});

  final String accountNo;
  final String password;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    return AlertDialog(
      title: const Text('记下这两样，就是你的账号'),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('不用注册、不用邮箱。换手机或者重装，用这两行就能把套餐带走。'),
            const SizedBox(height: 14),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
              decoration: BoxDecoration(
                color: theme.colorScheme.surfaceContainerHighest,
                borderRadius: BorderRadius.circular(12),
              ),
              child: Column(
                children: [
                  _row(theme, '账号编号', accountNo),
                  const Divider(height: 18),
                  _row(theme, '密码', password),
                ],
              ),
            ),
            const SizedBox(height: 12),
            // 说实话。不能藏，也不能等出事了才讲。
            Text(
              '没有邮箱的话，这两样丢了谁也找不回来，我们也不行。截个图或者抄在本子上。',
              style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.error),
            ),
            const SizedBox(height: 10),
            OutlinedButton.icon(
              icon: const Icon(Icons.copy_all_outlined, size: 18),
              label: const Text('复制这两行'),
              onPressed: () async {
                await Clipboard.setData(ClipboardData(
                  text: '光速雷达 账号编号：$accountNo\n密码：$password',
                ));
                if (context.mounted) {
                  ScaffoldMessenger.of(context)
                      .showSnackBar(const SnackBar(content: Text('已复制')));
                }
              },
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('以后再说'),
        ),
        TextButton(
          onPressed: () async {
            Navigator.pop(context);
            await showSetGuestPasswordDialog(context, ref);
          },
          child: const Text('换个密码'),
        ),
        FilledButton(
          onPressed: () async {
            await ref.read(panelAuthProvider.notifier).confirmGuestKeySaved();
            if (context.mounted) Navigator.pop(context);
          },
          child: const Text('我抄好了'),
        ),
      ],
    );
  }

  Widget _row(ThemeData theme, String label, String value) => Row(
        children: [
          Text(label, style: theme.textTheme.bodySmall),
          const Spacer(),
          SelectableText(
            value,
            style: theme.textTheme.titleMedium?.copyWith(
              fontFamily: 'monospace',
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      );
}

/// 换成自己记得住的密码。开号那串随机码作废，红点一起收掉。
Future<void> showSetGuestPasswordDialog(BuildContext context, WidgetRef ref) async {
  await showDialog<void>(
    context: context,
    builder: (ctx) => const _SetGuestPasswordDialog(),
  );
}

class _SetGuestPasswordDialog extends HookConsumerWidget {
  const _SetGuestPasswordDialog();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final pw1 = useTextEditingController();
    final pw2 = useTextEditingController();
    final error = useState<String?>(null);
    final busy = useState(false);
    final no = ref.watch(panelAuthProvider).accountNo ?? '';

    Future<void> save() async {
      error.value = null;
      if (pw1.text.length < 8) {
        error.value = '密码至少 8 位';
        return;
      }
      if (pw1.text != pw2.text) {
        error.value = '两次输入不一样';
        return;
      }
      busy.value = true;
      final err = await ref.read(panelAuthProvider.notifier).setGuestPassword(pw1.text);
      busy.value = false;
      if (err != null) {
        error.value = err;
        return;
      }
      if (context.mounted) {
        Navigator.pop(context);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('密码已设好。换手机时用账号编号 $no 加这个密码登录')),
        );
      }
    }

    return AlertDialog(
      title: const Text('设置密码'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('账号编号 $no 加上这个密码，换手机也能登回来。至少 8 位。'),
          const SizedBox(height: 12),
          TextField(
            controller: pw1,
            obscureText: true,
            decoration: const InputDecoration(labelText: '新密码'),
          ),
          const SizedBox(height: 8),
          TextField(
            controller: pw2,
            obscureText: true,
            decoration: const InputDecoration(labelText: '再输一次'),
            onSubmitted: (_) => save(),
          ),
          if (error.value != null) ...[
            const SizedBox(height: 10),
            Text(error.value!, style: TextStyle(color: Theme.of(context).colorScheme.error)),
          ],
        ],
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('取消')),
        FilledButton(onPressed: busy.value ? null : save, child: const Text('保存')),
      ],
    );
  }
}
