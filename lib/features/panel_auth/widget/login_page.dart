import 'package:flutter/material.dart';
import 'package:flutter_hooks/flutter_hooks.dart';
import 'package:go_router/go_router.dart';
import 'package:hiddify/core/model/constants.dart';
import 'package:hiddify/core/router/bottom_sheets/bottom_sheets_notifier.dart';
import 'package:hiddify/features/panel_auth/notifier/panel_auth.dart';
import 'package:hiddify/features/profile/model/profile_entity.dart';
import 'package:hiddify/features/profile/notifier/profile_notifier.dart';
import 'package:hiddify/utils/custom_text_form_field.dart';
import 'package:hiddify/utils/uri_utils.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

/// 光速会员账号登录。登录成功后自动把订阅加成配置并回主页。
class LoginPage extends HookConsumerWidget {
  const LoginPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final auth = ref.watch(panelAuthProvider);
    final formKey = useMemoized(() => GlobalKey<FormState>());
    final emailCtrl = useTextEditingController();
    final passCtrl = useTextEditingController();
    final obscure = useState(true);
    final errorText = useState<String?>(null);
    final busy = useState(false);

    Future<void> submit() async {
      errorText.value = null;
      if (!formKey.currentState!.validate()) return;
      busy.value = true;
      final result = await ref
          .read(panelAuthProvider.notifier)
          .login(emailCtrl.text.trim(), passCtrl.text);
      if (!context.mounted) return;
      if (result.error != null) {
        errorText.value = result.error;
        busy.value = false;
        return;
      }
      final url = result.subscribeUrl;
      if (url == null || url.isEmpty) {
        errorText.value = '登录成功，但没拿到订阅地址';
        busy.value = false;
        return;
      }
      // 固定名字「光速」—— 别用订阅 URL 的最后一段（那是 token，敏感）
      await ref.read(addProfileNotifierProvider.notifier).addManual(
            url: url,
            userOverride: const UserOverride(name: '光速'),
          );
      if (!context.mounted) return;
      busy.value = false;
      context.go('/home');
    }

    final loading = busy.value || auth.loading;

    return Scaffold(
      appBar: AppBar(title: const Text('登录光速账号')),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(20, 24, 20, 24),
          child: Form(
            key: formKey,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(
                  '用你在官网 / 电脑客户端的邮箱和密码登录，自动导入订阅。',
                  style: theme.textTheme.bodyMedium
                      ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                ),
                const SizedBox(height: 24),
                CustomTextFormField(
                  controller: emailCtrl,
                  maxLines: 1,
                  label: '邮箱',
                  hint: 'you@example.com',
                  validator: (v) =>
                      (v == null || !v.contains('@')) ? '请输入正确的邮箱' : null,
                ),
                const SizedBox(height: 16),
                CustomTextFormField(
                  controller: passCtrl,
                  maxLines: 1,
                  label: '密码',
                  validator: (v) =>
                      (v == null || v.isEmpty) ? '请输入密码' : null,
                  suffixIcon: IconButton(
                    icon: Icon(
                      obscure.value ? Icons.visibility_off : Icons.visibility,
                    ),
                    onPressed: () => obscure.value = !obscure.value,
                  ),
                ),
                if (errorText.value != null) ...[
                  const SizedBox(height: 12),
                  Text(
                    errorText.value!,
                    style: TextStyle(color: theme.colorScheme.error),
                  ),
                ],
                const SizedBox(height: 24),
                FilledButton(
                  onPressed: loading ? null : submit,
                  child: loading
                      ? const SizedBox(
                          height: 20,
                          width: 20,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Text('登录'),
                ),
                const SizedBox(height: 8),
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    TextButton(
                      onPressed: () => UriUtils.tryLaunch(Uri.parse(Constants.panelRegisterUrl)),
                      child: const Text('注册账号'),
                    ),
                    TextButton(
                      onPressed: () => context.pushNamed(
                        'resetPassword',
                        queryParameters: {if (emailCtrl.text.trim().isNotEmpty) 'email': emailCtrl.text.trim()},
                      ),
                      child: const Text('忘记密码'),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                TextButton(
                  onPressed: loading
                      ? null
                      : () {
                          if (context.canPop()) {
                            context.pop();
                          } else {
                            context.go('/home');
                          }
                          WidgetsBinding.instance.addPostFrameCallback((_) {
                            ref
                                .read(bottomSheetsNotifierProvider.notifier)
                                .showAddProfile();
                          });
                        },
                  child: const Text('已有订阅链接？手动添加'),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
