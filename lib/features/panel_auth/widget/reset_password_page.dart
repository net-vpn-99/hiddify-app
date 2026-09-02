import 'package:flutter/material.dart';
import 'package:flutter_hooks/flutter_hooks.dart';
import 'package:go_router/go_router.dart';
import 'package:hiddify/features/panel_auth/notifier/panel_auth.dart';
import 'package:hiddify/utils/custom_text_form_field.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

/// 用邮箱验证码重置密码（登录 / 未登录都能用）。
class ResetPasswordPage extends HookConsumerWidget {
  const ResetPasswordPage({super.key, this.email});

  final String? email;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final formKey = useMemoized(() => GlobalKey<FormState>());
    final emailCtrl = useTextEditingController(text: email ?? '');
    final passCtrl = useTextEditingController();
    final pass2Ctrl = useTextEditingController();
    final codeCtrl = useTextEditingController();
    final error = useState<String?>(null);
    final busy = useState(false);
    final cooldown = useState(0);

    Future<void> sendCode() async {
      if (cooldown.value > 0) return;
      if (!emailCtrl.text.contains('@')) {
        error.value = '请先填正确的邮箱';
        return;
      }
      error.value = null;
      final err = await ref.read(panelAuthProvider.notifier).sendEmailCode(emailCtrl.text.trim());
      if (!context.mounted) return;
      if (err != null) {
        error.value = err;
        return;
      }
      cooldown.value = 60;
      Future.doWhile(() async {
        await Future<void>.delayed(const Duration(seconds: 1));
        if (!context.mounted) return false;
        cooldown.value--;
        return cooldown.value > 0;
      });
    }

    Future<void> submit() async {
      error.value = null;
      if (!formKey.currentState!.validate()) return;
      busy.value = true;
      final err = await ref.read(panelAuthProvider.notifier).resetPassword(
            emailCtrl.text.trim(),
            passCtrl.text,
            codeCtrl.text.trim(),
          );
      if (!context.mounted) return;
      busy.value = false;
      if (err != null) {
        error.value = err;
        return;
      }
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('密码已重置，请用新密码登录')),
      );
      context.pop();
    }

    return Scaffold(
      appBar: AppBar(title: const Text('修改密码')),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(20, 20, 20, 24),
          child: Form(
            key: formKey,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                CustomTextFormField(
                  controller: emailCtrl,
                  maxLines: 1,
                  label: '邮箱',
                  validator: (v) => (v == null || !v.contains('@')) ? '请输入正确的邮箱' : null,
                ),
                const SizedBox(height: 16),
                CustomTextFormField(
                  controller: passCtrl,
                  maxLines: 1,
                  label: '新密码（至少 8 位）',
                  validator: (v) => (v == null || v.length < 8) ? '密码至少 8 位' : null,
                ),
                const SizedBox(height: 16),
                CustomTextFormField(
                  controller: pass2Ctrl,
                  maxLines: 1,
                  label: '再次输入新密码',
                  validator: (v) => v != passCtrl.text ? '两次输入不一致' : null,
                ),
                const SizedBox(height: 16),
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(
                      child: CustomTextFormField(
                        controller: codeCtrl,
                        maxLines: 1,
                        label: '邮箱验证码',
                        validator: (v) => (v == null || v.isEmpty) ? '请输入验证码' : null,
                      ),
                    ),
                    const SizedBox(width: 12),
                    Padding(
                      padding: const EdgeInsets.only(top: 6),
                      child: OutlinedButton(
                        onPressed: cooldown.value > 0 ? null : sendCode,
                        child: Text(cooldown.value > 0 ? '${cooldown.value}s' : '发送'),
                      ),
                    ),
                  ],
                ),
                if (error.value != null) ...[
                  const SizedBox(height: 12),
                  Text(error.value!, style: TextStyle(color: theme.colorScheme.error)),
                ],
                const SizedBox(height: 24),
                FilledButton(
                  onPressed: busy.value ? null : submit,
                  child: busy.value
                      ? const SizedBox(height: 20, width: 20, child: CircularProgressIndicator(strokeWidth: 2))
                      : const Text('重置密码'),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
