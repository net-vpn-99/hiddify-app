import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
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
    final pairCtrl = useTextEditingController();
    final passCtrl = useTextEditingController();
    final obscure = useState(true);
    final errorText = useState<String?>(null);
    final errorTick = useState(0);
    final busy = useState(false);
    final notice = useState<String?>(null);
    final pairMode = useState(true);
    final badPassword = useState(false);
    final badPair = useState(false);
    final passwordFocus = useFocusNode();
    final pairFocus = useFocusNode();

    void clearError() {
      errorText.value = null;
      badPassword.value = false;
      badPair.value = false;
    }

    void showError(String message, {required bool pair}) {
      errorText.value = message;
      errorTick.value++;
      if (pair) {
        badPair.value = true;
        pairCtrl.clear();
        pairFocus.requestFocus();
      } else {
        badPassword.value = true;
        passCtrl.clear();
        passwordFocus.requestFocus();
      }
    }

    useEffect(() {
      final saved = ref.read(Preferences.lastLoginEmail);
      final boot = ref.read(guestBootstrapProvider);
      final mask = boot.knownAccountMask;
      final no = boot.knownAccountNo ?? '';
      // 先填这台手机上次登录用的；重装后没有，就填服务端认出来的账号编号（打码邮箱填不进去）。
      if (emailCtrl.text.isEmpty) emailCtrl.text = saved.isNotEmpty ? saved : (mask != null ? no : '');
      pairMode.value = mask == null && saved.isEmpty;
      if (mask != null) {
        final who = mask.isEmpty ? '这台手机上有账号' : '这台手机上是 $mask';
        // 只有输入框里真的已经填好了，才说「输入密码就能登录」。
        notice.value = emailCtrl.text.isNotEmpty
            ? (saved.isEmpty ? '$who，账号编号已经填好，输入密码就能登录；忘了密码点「找回密码」' : '$who，输入密码就能登录；忘了密码点「找回密码」')
            : '$who，填上这个邮箱和密码登录；忘了密码点「找回密码」';
      }
      return null;
    }, const []);

    /// 游客号上还有没到期的套餐：先问要不要加邮箱（不然登录别的号后这个号就找不回来了）。
    /// 返回 true = 接着登录；false = 不登录了（去加邮箱 / 关掉了弹窗）。
    Future<bool> okToLeaveGuest() async {
      if (!ref.read(panelAuthProvider).isGuest) return true;
      final paid = await ref.read(panelAuthProvider.notifier).guestHasPaidOrder();
      if (!context.mounted) return false;
      final exp = ref.read(panelAuthProvider).account?.expiredAt;
      final dated = exp != null && exp != 0;
      final stillValid = !dated || exp > DateTime.now().millisecondsSinceEpoch ~/ 1000;
      if (paid != true || !stillValid) return true;
      String when() {
        final d = DateTime.fromMillisecondsSinceEpoch(exp! * 1000);
        return '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';
      }
      final choice = await showDialog<String>(
        context: context,
        builder: (ctx) => AlertDialog(
          content: Text(dated
              ? '这个号上还有套餐（到 ${when()}），先加个邮箱再登录别的账号。'
              : '这个号上还有套餐，先加个邮箱再登录别的账号。'),
          actions: [
            TextButton(onPressed: () => Navigator.of(ctx).pop('login'), child: const Text('直接登录')),
            FilledButton(onPressed: () => Navigator.of(ctx).pop('bind'), child: const Text('加邮箱')),
          ],
        ),
      );
      if (!context.mounted) return false;
      if (choice == 'login') return true;
      busy.value = false;
      if (choice == 'bind') context.pushNamed('bindEmail');
      return false;
    }

    Future<void> submitPair() async {
      final code = pairCtrl.text.trim();
      if (code.length != 6 || busy.value) return;
      errorText.value = null;
      busy.value = true;
      if (!await okToLeaveGuest()) return;
      final result = await ref.read(panelAuthProvider.notifier).loginWithPairCode(code);
      if (!context.mounted) return;
      if (result.error != null) {
        showError(result.error!, pair: true);
        busy.value = false;
        return;
      }
      final url = result.subscribeUrl;
      if (url != null && url.isNotEmpty) {
        await ref.read(addProfileNotifierProvider.notifier).addAccountSubscription(url);
      }
      try {
        await ref.read(connectionNotifierProvider.notifier).abortConnection();
      } catch (_) {}
      if (!context.mounted) return;
      busy.value = false;
      final who = ref.read(panelAuthProvider).accountNo ?? ref.read(panelAuthProvider).email ?? '';
      ScaffoldMessenger.maybeOf(context)?.showSnackBar(SnackBar(content: Text('已登录 账号 $who')));
      context.go('/home');
    }

    Future<void> submit() async {
      // 正在开游客号 / 正在登录时不重复提交（按钮这时是转圈；键盘「完成」键也会走到这里）。
      if (busy.value || ref.read(panelAuthProvider).loading) return;
      errorText.value = null;
      if (!formKey.currentState!.validate()) return;
      busy.value = true;
      if (!await okToLeaveGuest()) return;
      final result = await ref
          .read(panelAuthProvider.notifier)
          .login(emailCtrl.text.trim(), passCtrl.text);
      if (!context.mounted) return;
      if (result.error != null) {
        showError(result.error!, pair: false);
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

    final loading = busy.value || auth.loading;

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
                SegmentedButton<bool>(
                  segments: const [
                    ButtonSegment(value: true, label: Text('配对码')),
                    ButtonSegment(value: false, label: Text('邮箱 / 账号编号')),
                  ],
                  selected: {pairMode.value},
                  onSelectionChanged: (next) {
                    pairMode.value = next.first;
                    clearError();
                  },
                ),
                const SizedBox(height: 16),
                if (pairMode.value) ...[
                  Text(
                    '在已经登录的那台设备上：账号 →「在另一台设备上用」，拿到 6 位配对码。',
                    style: theme.textTheme.bodyMedium?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                  ),
                  const SizedBox(height: 12),
                  TextFormField(
                    controller: pairCtrl,
                    focusNode: pairFocus,
                    keyboardType: TextInputType.number,
                    maxLength: 6,
                    inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                    decoration: InputDecoration(
                      hintText: '6 位数字',
                      counterText: '',
                      enabledBorder: OutlineInputBorder(
                        borderSide: BorderSide(color: badPair.value ? theme.colorScheme.error : theme.colorScheme.outline),
                      ),
                      focusedBorder: OutlineInputBorder(
                        borderSide: BorderSide(
                          color: badPair.value ? theme.colorScheme.error : theme.colorScheme.primary,
                          width: badPair.value ? 2 : 1,
                        ),
                      ),
                    ),
                    onChanged: (v) {
                      if (v.isNotEmpty) clearError();
                      if (v.length == 6) submitPair();
                    },
                  ),
                  if (errorText.value != null) ...[
                    const SizedBox(height: 12),
                    _LoginError(text: errorText.value!, tick: errorTick.value),
                  ],
                  const SizedBox(height: 12),
                  FilledButton(
                    onPressed: loading ? null : submitPair,
                    child: loading
                        ? const SizedBox(height: 20, width: 20, child: CircularProgressIndicator(strokeWidth: 2))
                        : const Text('登录'),
                  ),
                ] else ...[
                  if (notice.value != null) ...[
                    Container(
                      padding: const EdgeInsets.all(14),
                      decoration: BoxDecoration(
                        color: theme.colorScheme.primaryContainer,
                        borderRadius: BorderRadius.circular(12),
                      ),
                      child: Text(
                        notice.value!,
                        style: theme.textTheme.titleSmall?.copyWith(color: theme.colorScheme.onPrimaryContainer),
                      ),
                    ),
                    const SizedBox(height: 16),
                  ],
                  CustomTextFormField(
                    controller: emailCtrl,
                    maxLines: 1,
                    label: '邮箱 或 账号编号',
                    hint: 'you@example.com 或 A4K7-P92',
                    onChanged: (_) => clearError(),
                    validator: (v) {
                      final s = v?.trim() ?? '';
                      if (s.isEmpty) return '请输入邮箱或账号编号';
                      if (s.contains('@')) return null;
                      return s.replaceAll('-', '').length < 6 ? '账号编号填完整，像 A4K7-P92' : null;
                    },
                  ),
                  const SizedBox(height: 16),
                  TextFormField(
                    controller: passCtrl,
                    focusNode: passwordFocus,
                    obscureText: obscure.value,
                    // 输完密码按键盘上的「完成」直接登录（10-16 运营：只认下面的按钮，按键盘键没有任何反应）。
                    textInputAction: TextInputAction.done,
                    onFieldSubmitted: (_) => submit(),
                    decoration: InputDecoration(
                      labelText: '密码',
                      enabledBorder: OutlineInputBorder(
                        borderSide: BorderSide(color: badPassword.value ? theme.colorScheme.error : theme.colorScheme.outline),
                      ),
                      focusedBorder: OutlineInputBorder(
                        borderSide: BorderSide(
                          color: badPassword.value ? theme.colorScheme.error : theme.colorScheme.primary,
                          width: badPassword.value ? 2 : 1,
                        ),
                      ),
                      suffixIcon: IconButton(
                        icon: Icon(obscure.value ? Icons.visibility_off : Icons.visibility),
                        onPressed: () => obscure.value = !obscure.value,
                      ),
                    ),
                    validator: (v) => (v == null || v.isEmpty) ? '请输入密码' : null,
                    onChanged: (v) {
                      if (v.isNotEmpty) clearError();
                    },
                  ),
                  if (errorText.value != null) ...[
                    const SizedBox(height: 12),
                    _LoginError(text: errorText.value!, tick: errorTick.value),
                  ],
                  const SizedBox(height: 12),
                  FilledButton(
                    onPressed: loading ? null : submit,
                    child: loading
                        ? const SizedBox(height: 20, width: 20, child: CircularProgressIndicator(strokeWidth: 2))
                        : const Text('登录'),
                  ),
                  const SizedBox(height: 8),
                  Align(
                    alignment: Alignment.centerRight,
                    child: TextButton(
                      onPressed: () => context.pushNamed(
                        'resetPassword',
                        // 输入框里可能是账号编号，找回密码只认邮箱，编号别带过去。
                        queryParameters: {if (emailCtrl.text.contains('@')) 'email': emailCtrl.text.trim()},
                      ),
                      child: const Text('找回密码'),
                    ),
                  ),
                ],
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

class _LoginError extends HookWidget {
  const _LoginError({required this.text, required this.tick});

  final String text;
  final int tick;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final ctrl = useAnimationController(duration: const Duration(milliseconds: 180));
    useEffect(() {
      if (tick > 0) ctrl.forward(from: 0);
      return null;
    }, [tick]);
    final t = useAnimation(ctrl);
    final dx = math.sin(t * math.pi * 3) * 6 * (1 - t);
    return Transform.translate(
      offset: Offset(dx, 0),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        decoration: BoxDecoration(
          color: theme.colorScheme.errorContainer,
          borderRadius: BorderRadius.circular(10),
        ),
        child: Row(
          children: [
            Icon(Icons.warning_amber_rounded, color: theme.colorScheme.onErrorContainer),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                text,
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: theme.colorScheme.onErrorContainer,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
