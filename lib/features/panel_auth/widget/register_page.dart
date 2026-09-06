import 'package:flutter/material.dart';
import 'package:flutter_hooks/flutter_hooks.dart';
import 'package:go_router/go_router.dart';
import 'package:hiddify/core/model/constants.dart';
import 'package:hiddify/features/panel_auth/notifier/panel_auth.dart';
import 'package:hiddify/features/profile/model/profile_entity.dart';
import 'package:hiddify/features/profile/notifier/profile_notifier.dart';
import 'package:hiddify/utils/custom_text_form_field.dart';
import 'package:hiddify/utils/uri_utils.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

typedef _Opts = ({bool emailVerify, bool inviteForce, bool recaptcha});

/// 注册光速账号（App 内完成）。站点开了人机验证时退回浏览器。
class RegisterPage extends HookConsumerWidget {
  const RegisterPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final formKey = useMemoized(() => GlobalKey<FormState>());
    final emailCtrl = useTextEditingController();
    final passCtrl = useTextEditingController();
    final pass2Ctrl = useTextEditingController();
    final codeCtrl = useTextEditingController();
    final inviteCtrl = useTextEditingController();
    final obscure = useState(true);
    final error = useState<String?>(null);
    final busy = useState(false);
    final cooldown = useState(0);
    final opts = useState<_Opts?>(null);

    useEffect(() {
      () async {
        opts.value = await ref.read(panelAuthProvider.notifier).registerOptions();
      }();
      return null;
    }, const []);

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
      final result = await ref.read(panelAuthProvider.notifier).register(
            emailCtrl.text.trim(),
            passCtrl.text,
            code: codeCtrl.text.trim(),
            inviteCode: inviteCtrl.text.trim(),
          );
      if (!context.mounted) return;
      if (result.error != null) {
        error.value = result.error;
        busy.value = false;
        return;
      }
      final url = result.subscribeUrl;
      if (url != null && url.isNotEmpty) {
        await ref.read(addProfileNotifierProvider.notifier).addManual(
              url: url,
              userOverride: const UserOverride(name: '光速'),
            );
      }
      if (!context.mounted) return;
      busy.value = false;
      context.go('/home');
    }

    final o = opts.value;

    return Scaffold(
      appBar: AppBar(title: const Text('注册光速账号')),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(20, 20, 20, 24),
          child: o != null && o.recaptcha
              ? _recaptchaFallback(context, theme)
              : Form(
                  key: formKey,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Text(
                        '注册成功即自动开通试用，登录后自动导入订阅。',
                        style: theme.textTheme.bodyMedium?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                      ),
                      const SizedBox(height: 20),
                      CustomTextFormField(
                        controller: emailCtrl,
                        maxLines: 1,
                        label: '邮箱',
                        hint: 'you@example.com',
                        validator: (v) => (v == null || !v.contains('@')) ? '请输入正确的邮箱' : null,
                      ),
                      const SizedBox(height: 16),
                      CustomTextFormField(
                        controller: passCtrl,
                        maxLines: 1,
                        label: '密码（至少 8 位）',
                        obscureText: obscure.value,
                        validator: (v) => (v == null || v.length < 8) ? '密码至少 8 位' : null,
                        suffixIcon: IconButton(
                          icon: Icon(obscure.value ? Icons.visibility_off : Icons.visibility),
                          onPressed: () => obscure.value = !obscure.value,
                        ),
                      ),
                      const SizedBox(height: 16),
                      CustomTextFormField(
                        controller: pass2Ctrl,
                        maxLines: 1,
                        label: '再次输入密码',
                        obscureText: obscure.value,
                        validator: (v) => v != passCtrl.text ? '两次输入不一致' : null,
                      ),
                      if (o == null || o.emailVerify) ...[
                        const SizedBox(height: 16),
                        Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Expanded(
                              child: CustomTextFormField(
                                controller: codeCtrl,
                                maxLines: 1,
                                label: '邮箱验证码',
                                validator: (v) {
                                  if (o != null && !o.emailVerify) return null;
                                  return (v == null || v.isEmpty) ? '请输入验证码' : null;
                                },
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
                      ],
                      const SizedBox(height: 16),
                      CustomTextFormField(
                        controller: inviteCtrl,
                        maxLines: 1,
                        label: (o != null && o.inviteForce) ? '邀请码' : '邀请码（选填）',
                        validator: (v) {
                          if (o != null && o.inviteForce && (v == null || v.trim().isEmpty)) {
                            return '本站注册需要邀请码';
                          }
                          return null;
                        },
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
                            : const Text('注册并登录'),
                      ),
                      const SizedBox(height: 8),
                      TextButton(
                        onPressed: () => context.canPop() ? context.pop() : context.go('/login'),
                        child: const Text('已有账号？去登录'),
                      ),
                    ],
                  ),
                ),
        ),
      ),
    );
  }

  Widget _recaptchaFallback(BuildContext context, ThemeData theme) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const SizedBox(height: 24),
        Text(
          '本站注册需要完成人机验证，请在浏览器里注册；注册好后回到 App 用邮箱密码登录即可。',
          style: theme.textTheme.bodyMedium,
        ),
        const SizedBox(height: 24),
        FilledButton.icon(
          icon: const Icon(Icons.open_in_new),
          label: const Text('在浏览器注册'),
          onPressed: () => UriUtils.tryLaunch(Uri.parse(Constants.panelRegisterUrl)),
        ),
        const SizedBox(height: 8),
        TextButton(
          onPressed: () => context.canPop() ? context.pop() : context.go('/login'),
          child: const Text('返回登录'),
        ),
      ],
    );
  }
}
