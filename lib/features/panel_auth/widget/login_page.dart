import 'package:flutter/material.dart';
import 'package:flutter_hooks/flutter_hooks.dart';
import 'package:go_router/go_router.dart';
import 'package:hiddify/core/preferences/general_preferences.dart';
import 'package:hiddify/features/panel_auth/notifier/guest_bootstrap.dart';
import 'package:hiddify/features/panel_auth/notifier/panel_auth.dart';
import 'package:hiddify/features/profile/notifier/profile_notifier.dart';
import 'package:hiddify/utils/custom_text_form_field.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

/// 光速会员账号登录。登录成功后自动把订阅加成配置并回主页。
///
/// 1.1.28 起这一页**不再是必经之路**：装好打开直接进首页，游客号在首页后台开
/// （guestBootstrapProvider）。到这一页只有两种人 —— 首页点了「已有账号？去登录」的，
/// 和游客开不出来时点提示条进来的。所以这里不再自动开号，只留一个手动按钮。
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
    // 免注册试用（GslGuest）：服务端开着才显示；guestBusy = 正在开号。
    final guestEnabled = useState(false);
    final guestBusy = useState(false);
    final notice = useState<String?>(null);

    // 用户主动点「免注册，直接试用」：开号走首页那套（同一把锁，不会开两个号），
    // 顺便把之前的「已退出」标记清掉，以后打开又能自动开号了。
    Future<void> startGuest() async {
      errorText.value = null;
      notice.value = null;
      guestBusy.value = true;
      final boot = ref.read(guestBootstrapProvider.notifier);
      boot.reset();
      await ref.read(Preferences.guestOptOut.notifier).update(false);
      await boot.ensure();
      if (!context.mounted) return;
      guestBusy.value = false;
      final st = ref.read(guestBootstrapProvider);
      if (!st.blocked) {
        context.go('/home');
        return;
      }
      if (st.reason == GuestBlockReason.hasAccount) {
        notice.value = st.message;
      } else {
        errorText.value = st.message ?? '免注册试用暂时不可用，请注册账号';
      }
    }

    // 服务端开着游客才显示那个按钮；这里只读开关，不自动开号。
    useEffect(() {
      Future(() async {
        final opts = await ref.read(panelAuthProvider.notifier).guestOptions();
        if (!context.mounted) return;
        guestEnabled.value = opts.enabled;
        final boot = ref.read(guestBootstrapProvider);
        if (boot.reason == GuestBlockReason.hasAccount) notice.value = boot.message;
      });
      return null;
    }, const []);

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
      await ref.read(addProfileNotifierProvider.notifier).addAccountSubscription(url);
      if (!context.mounted) return;
      busy.value = false;
      context.go('/home');
    }

    final loading = busy.value || auth.loading || guestBusy.value;

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
                // 这台手机登过正式账号：不给游客（防卸载重装反复领试用），按钮收起来，
                // 提示放显眼处——不然还摆着「免注册」按钮，点了只会再弹同一句话。
                if (notice.value != null) ...[
                  const SizedBox(height: 20),
                  Container(
                    padding: const EdgeInsets.all(14),
                    decoration: BoxDecoration(
                      color: theme.colorScheme.primaryContainer,
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          notice.value!,
                          style: theme.textTheme.titleSmall
                              ?.copyWith(color: theme.colorScheme.onPrimaryContainer),
                        ),
                        const SizedBox(height: 4),
                        Text(
                          '用这个账号的邮箱和密码登录就行；忘了密码点下面「忘记密码」。想换个新账号，点「注册账号」。',
                          style: theme.textTheme.bodySmall
                              ?.copyWith(color: theme.colorScheme.onPrimaryContainer),
                        ),
                      ],
                    ),
                  ),
                ] else if (guestEnabled.value) ...[
                  const SizedBox(height: 20),
                  FilledButton.tonal(
                    onPressed: loading ? null : startGuest,
                    child: guestBusy.value
                        ? const Row(
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              SizedBox(height: 18, width: 18, child: CircularProgressIndicator(strokeWidth: 2)),
                              SizedBox(width: 10),
                              Text('正在开通免费试用…'),
                            ],
                          )
                        : const Text('免注册，直接试用'),
                  ),
                  const SizedBox(height: 6),
                  Text(
                    '不用填邮箱，打开就能用。买套餐时再绑定邮箱。',
                    textAlign: TextAlign.center,
                    style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                  ),
                ],
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
                  obscureText: obscure.value,
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
                      onPressed: () => context.pushNamed('register'),
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
              ],
            ),
          ),
        ),
      ),
    );
  }
}
