import 'dart:async';
import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:go_router/go_router.dart';
import 'package:hiddify/core/utils/device_id.dart';
import 'package:hiddify/features/panel_auth/data/panel_api.dart';
import 'package:hiddify/features/panel_auth/notifier/panel_auth.dart';
import 'package:hiddify/utils/uri_utils.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:qr_flutter/qr_flutter.dart';

class AddDevicePage extends ConsumerStatefulWidget {
  const AddDevicePage({super.key});

  @override
  ConsumerState<AddDevicePage> createState() => _AddDevicePageState();
}

class _AddDevicePageState extends ConsumerState<AddDevicePage> {
  bool iphone = false;
  bool codeIssued = false;
  bool pairFull = false;
  bool pairGuest = false;
  int? limitAfterBind;
  String code = '';
  int secondsLeft = 0;
  int used = 0;
  int limit = 0;
  String errorText = '';
  String scanText = '';
  String subUrl = '';
  List<Map<String, dynamic>> devices = const [];
  String mineHash = '';
  Timer? ticker;

  @override
  void initState() {
    super.initState();
    ticker = Timer.periodic(const Duration(seconds: 1), (_) {
      if (secondsLeft > 0 && mounted) setState(() => secondsLeft--);
    });
    _load();
  }

  @override
  void dispose() {
    ticker?.cancel();
    super.dispose();
  }

  Future<void> _load() async {
    final token = await ref.read(panelAuthProvider.notifier).currentToken();
    final id = await DeviceId.read();
    if (id != null) {
      mineHash = sha256.convert(utf8.encode('gsl_guest|$id')).toString().substring(0, 16);
    }
    if (token == null || token.isEmpty) return;
    await Future.wait([_loadPair(token), _loadDevices(token)]);
  }

  Future<void> _loadPair(String token) async {
    try {
      final pair = await PanelApi().createPairCode(token);
      if (!mounted) return;
      setState(() {
        pairFull = pair.full;
        pairGuest = pair.guest;
        limitAfterBind = pair.limitAfterBind;
        used = pair.used;
        limit = pair.limit;
        codeIssued = !pair.full;
        code = pair.full ? '' : pair.code;
        secondsLeft = pair.full ? 0 : (pair.expiresIn > 0 ? pair.expiresIn : 600);
        errorText = '';
      });
    } on PanelApiException catch (e) {
      if (!mounted) return;
      setState(() {
        codeIssued = false;
        pairFull = false;
        code = '';
        secondsLeft = 0;
        errorText = e.message;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        codeIssued = false;
        pairFull = false;
        code = '';
        secondsLeft = 0;
        errorText = '网络不好，稍后再试';
      });
    }
  }

  Future<void> _loadDevices(String token) async {
    try {
      final list = await PanelApi().fetchDevices(token);
      if (!mounted) return;
      setState(() {
        used = list.used;
        limit = list.limit;
        devices = list.devices;
      });
    } catch (_) {}
  }

  Future<void> _loadIphone() async {
    if (scanText.isNotEmpty) return;
    final token = await ref.read(panelAuthProvider.notifier).currentToken();
    if (token == null) return;
    try {
      final qr = await PanelApi().fetchIphoneQr(token);
      if (!mounted) return;
      setState(() {
        scanText = qr.scanText;
        subUrl = qr.subUrl;
      });
    } on PanelApiException catch (e) {
      if (mounted) setState(() => errorText = e.message);
    } catch (_) {
      if (mounted) setState(() => errorText = '网络不好，稍后再试');
    }
  }

  String get _clock {
    if (secondsLeft <= 0) return '已失效 · 换一个';
    final m = secondsLeft ~/ 60;
    final s = (secondsLeft % 60).toString().padLeft(2, '0');
    return '$m:$s 后失效';
  }

  String _when(Map<String, dynamic> row) {
    if (row['connected'] == true) return '在线';
    final seen = row['last_seen'];
    final sec = seen is num ? seen.toInt() : int.tryParse('$seen') ?? 0;
    if (sec <= 0) return '今天';
    final days = (DateTime.now().millisecondsSinceEpoch ~/ 1000 - sec) ~/ 86400;
    return days <= 0 ? '今天' : '$days 天前';
  }

  String _label(String? platform) {
    if (platform == 'android') return '安卓手机';
    if (platform == 'windows') return 'Windows 电脑';
    return platform ?? '';
  }

  @override
  Widget build(BuildContext context) {
    final grouped = code.length == 6 ? '${code.substring(0, 3)} ${code.substring(3)}' : code;
    return Scaffold(
      appBar: AppBar(title: const Text('在另一台设备上用这个账号')),
      body: ListView(
        padding: const EdgeInsets.all(20),
        children: [
          SegmentedButton<bool>(
            segments: const [
              ButtonSegment(value: false, label: Text('电脑 / 安卓手机')),
              ButtonSegment(value: true, label: Text('iPhone')),
            ],
            selected: {iphone},
            onSelectionChanged: (v) {
              setState(() => iphone = v.first);
              if (iphone) _loadIphone();
            },
          ),
          const SizedBox(height: 20),
          if (!iphone) ...[
            if (pairFull && pairGuest) ...[
              const Text('这个账号还不能在第二台设备上用', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700)),
              const SizedBox(height: 8),
              Text(limitAfterBind != null
                  ? '免注册号只能在 1 台设备上用。你绑定邮箱后，这个账号最多可以用 $limitAfterBind 台设备，绑定不花钱。'
                  : '免注册号只能在 1 台设备上用。你绑定邮箱后，这个账号可以用多台设备，绑定不花钱。'),
              const SizedBox(height: 12),
              FilledButton(
                onPressed: () async {
                  final bound = await context.pushNamed<bool>('bindEmail');
                  if (bound == true && mounted) {
                    final token = await ref.read(panelAuthProvider.notifier).currentToken();
                    if (token != null && token.isNotEmpty) await _loadPair(token);
                  }
                },
                child: const Text('绑定邮箱'),
              ),
            ] else if (pairFull) ...[
              Text('这个账号已经在 $used 台设备上用了（最多 $limit 台）。不用的设备 45 天后会自动让出位置；你急用，请联系客服。'),
              const SizedBox(height: 12),
              OutlinedButton(
                onPressed: () => UriUtils.tryLaunch(Uri.parse('https://www.gsldone.com/support.html')),
                child: const Text('联系客服'),
              ),
            ] else ...[
              if (codeIssued) ...[
                Text(grouped, textAlign: TextAlign.center, style: const TextStyle(fontSize: 36, fontWeight: FontWeight.w700, letterSpacing: 2)),
                const SizedBox(height: 8),
                Text(_clock, textAlign: TextAlign.center),
              ],
              if (codeIssued && secondsLeft <= 0)
                TextButton(onPressed: () async {
                  final token = await ref.read(panelAuthProvider.notifier).currentToken();
                  if (token != null && token.isNotEmpty) await _loadPair(token);
                }, child: const Text('换一个')),
              if (!codeIssued && errorText.isNotEmpty)
                TextButton(onPressed: () async {
                  final token = await ref.read(panelAuthProvider.notifier).currentToken();
                  if (token != null && token.isNotEmpty) await _loadPair(token);
                }, child: const Text('再试一次')),
              const SizedBox(height: 12),
              const Text('在那台设备上打开光速雷达，点「已有账号？」，输入上面这 6 位数。'),
              const SizedBox(height: 8),
              const SelectableText('还没装？到 www.gsldone.com 下载'),
              if (limit > 0) ...[
                const SizedBox(height: 8),
                Text('这个账号现在 $used/$limit 台设备。'),
              ],
            ],
          ] else ...[
            if (scanText.isNotEmpty)
              Center(child: QrImageView(data: scanText, size: 200, backgroundColor: Colors.white)),
            const SizedBox(height: 12),
            const Text('① iPhone 上装 Shadowrocket（需要非中国区 Apple ID）② 打开它，点左上角扫码 ③ 对准这个二维码'),
            TextButton(
              onPressed: () => UriUtils.tryLaunch(Uri.parse('https://www.gsldone.com/ios/')),
              child: const Text('详细步骤'),
            ),
            if (subUrl.isNotEmpty)
              OutlinedButton(
                onPressed: () async {
                  await Clipboard.setData(ClipboardData(text: subUrl));
                  if (!context.mounted) return;
                  ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('订阅地址已复制')));
                },
                child: const Text('复制订阅地址'),
              ),
            const Text('iPhone 不占设备数。'),
          ],
          if (errorText.isNotEmpty) ...[
            const SizedBox(height: 12),
            Text(errorText, style: TextStyle(color: Theme.of(context).colorScheme.error)),
          ],
          const SizedBox(height: 20),
          Text(limit > 0 ? '这个账号在用的设备（$used/$limit）' : '这个账号在用的设备',
              style: const TextStyle(fontWeight: FontWeight.w600)),
          for (final row in devices)
            ListTile(
              contentPadding: EdgeInsets.zero,
              title: Text('${_label(row['platform'] as String?)}${(row['id_hash'] ?? '').toString().toLowerCase() == mineHash ? '（本机）' : ''}'),
              subtitle: Text(_when(row)),
            ),
          const Text('iPhone 和其它软件不算在这里。不用的设备 45 天后自动让出位置。'),
        ],
      ),
    );
  }
}
