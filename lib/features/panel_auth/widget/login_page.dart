import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_hooks/flutter_hooks.dart';
import 'package:go_router/go_router.dart';
import 'package:hiddify/core/preferences/general_preferences.dart';
import 'package:hiddify/features/connection/notifier/connection_notifier.dart';
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
      // 游客直接登录（没先退出）时这一步是**按 ID 原地换 URL**，不会多出第二条订阅。
      await ref.read(addProfileNotifierProvider.notifier).addAccountSubscription(url);
      // 换了账号就是换了订阅：还连着的话先断开，别让人以为还在用刚才那条线路。
      try {
        await ref.read(connectionNotifierProvider.notifier).abortConnection();
      } catch (_) {}
      // 登记这台设备。原来只有连接时才登记，所以「登录过但没连过」的人重装 App 之后
      // 认不出来，会被当成新设备开一个游客号（线上 242 个正式用户只有 38 个有登记）。
      unawaited(ref.read(panelAuthProvider.notifier).claimDevice(connected: false));
      if (!context.mounted) return;
      busy.value = false;
      // 结果说在这里：登完告诉他现在是哪个号，比登录前解释「试用会不会带过去」有用。
      // 用服务端回来的邮箱，不用输入框 —— 他可能是拿账号编号登的。
      final who = ref.read(panelAuthProvider).email ?? emailCtrl.text.trim();
      ScaffoldMessenger.maybeOf(context)?.showSnackBar(
        SnackBar(content: Text('已切换到 $who')),
      );
      context.go('/home');
    }

    final loading = busy.value || auth.loading || guestBusy.value;

    return Scaffold(
      appBar: AppBar(title: const Text('登录光速雷达账号')),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(20, 24, 20, 24),
          child: Form(
            key: formKey,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                // 第一次打开这页的人要先知道「这页是给谁用的」。原来写的是
                // 「…自动导入订阅」——「订阅」是我们内部的说法，客户不懂。
                Text(
                  '注册过的账号：填邮箱或账号编号，加上密码就能登。',
                  style: theme.textTheme.bodyMedium
                      ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                ),
                // 这里原来还有一句「当前的免费试用不会跟过去」——删了。
                // 用户点进来的入口就叫「登录已有账号」，他清楚自己要干什么；在登录前解释
                // 一个他不关心的机制（试用归属），只会让人看不懂、还以为有什么风险。
                // 结果用登录成功后的一条提示交代（「已切换到 xxx」），不在事前吓人。
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
                  // 已经在用试用的人不该看到「免注册，直接试用」—— 他就是从那个试用点
                  // 进来的，这颗按钮只会让他以为自己还没开通。只给真正没账号的人看。
                ] else if (guestEnabled.value && !auth.isGuest) ...[
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
                    '不用填邮箱，打开就能用。想换手机或在电脑上也用，以后再注册。',
                    textAlign: TextAlign.center,
                    style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                  ),
                ],
                const SizedBox(height: 24),
                CustomTextFormField(
                  controller: emailCtrl,
                  maxLines: 1,
                  // 账号编号和邮箱是同一个账号的两个名字（编号是 uuid 派生的，注册前后
                  // 不变）。带 @ 走 Xboard 登录，不带走 GslGuest 的 login-by-no。
                  label: '邮箱 或 账号编号',
                  hint: 'you@example.com 或 A4K7-P92',
                  validator: (v) {
                    final s = v?.trim() ?? '';
                    if (s.isEmpty) return '请输入邮箱或账号编号';
                    if (s.contains('@')) return null;
                    return s.replaceAll('-', '').length < 6 ? '账号编号填完整，像 A4K7-P92' : null;
                  },
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
                      // 游客不该走「注册」—— 那会新开一个账号，他现在的试用和买过的套餐
                      // 都留在旧号上（旧号只认这台手机，等于白丢）。他要的是把现在这个号
                      // 变成自己的，那叫「绑定邮箱」。两个页面长得一样，更得把入口分清。
                      onPressed: () => context.pushNamed(auth.isGuest ? 'bindEmail' : 'register'),
                      child: const Text('还没有账号？去注册'),
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
                // 退出登录后是 go('/login')，导航栈被清空 = 没有返回箭头。没有这个出口，
                // 不想登录的人只能杀掉 App 才回得了首页（用户反馈过）。首页本来就不拦人。
                if (!context.canPop()) ...[
                  const SizedBox(height: 4),
                  TextButton(
                    onPressed: () => context.go('/home'),
                    child: const Text('先回首页看看'),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}
