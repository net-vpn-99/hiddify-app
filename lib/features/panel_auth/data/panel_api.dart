import 'dart:async';
import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:hiddify/core/logger/logger.dart';
import 'package:hiddify/core/model/constants.dart';
import 'package:hiddify/core/model/remote_site_config.dart';
import 'package:hiddify/features/panel_auth/data/altcha.dart';
import 'package:hiddify/features/panel_auth/data/comm_config.dart';
import 'package:hiddify/features/panel_auth/data/own_subscribe.dart';
import 'package:hiddify/features/panel_auth/data/panel_api_base.dart';
import 'package:hiddify/features/panel_auth/model/invite_referral.dart';
import 'package:hiddify/features/proxy/model/node_display.dart';

/// 游客试用的服务端开关与文案（GslGuest 插件下发，改了不用发版）。
typedef GuestOptions = ({bool enabled, String suffix, String? bindBonusText, bool canBuy, bool selfPassword});

/// 邀请页要的服务端文案和规则（见 [PanelApi.getInviteTexts]）。
typedef InviteTexts = ({
  String? bonus,
  String? share,
  String? linkTemplate,
  String? paidBonus,
  String? goalText,
  int? goal,
  int? paidMinYuan,
  int? rate,
});

/// 对接 Xboard 会员系统。接口与桌面版 OneRay 保持一致
/// （见 VPN 仓库 src/control/XboardControlPlane.cpp）。
class PanelApi {
  PanelApi({Dio? dio}) : _dio = dio ?? PanelApiBase.dio();

  final Dio _dio;

  /// 登录，成功返回 auth 令牌（用于后续请求头 `auth_data`）。
  /// 失败抛 [PanelApiException]，message 为可直接展示给用户的中文。
  Future<String> login(String email, String password) async {
    Response<dynamic> res;
    try {
      res = await _dio.post<dynamic>(
        '/api/v1/passport/auth/login',
        data: {'email': email, 'password': password},
      );
    } on DioException catch (e) {
      throw PanelApiException.network(e, _networkMessage(e));
    }
    final token = _extractToken(res.data);
    if (token != null && token.isNotEmpty) return token;

    final msg = _messageOf(res.data, res.statusCode) ?? '登录失败，请检查邮箱和密码';
    throw PanelApiException(msg);
  }

  /// 用「账号编号 + 密码」登录（GslGuest 1.2.0 的 login-by-no）。
  ///
  /// 编号就是 App 里显示的那串 `A4K7-P92`（uuid 前 8 位换算来的，注册前后都不变），
  /// 所以用户可以用编号或邮箱登录同一个账号。没注册过的号密码是随机的，登不上。
  Future<String> loginByAccountNo(String accountNo, String password) async {
    Response<dynamic> res;
    try {
      res = await _dio.post<dynamic>(
        '/api/v1/guest/gsl_guest/login-by-no',
        data: {'account_no': accountNo, 'password': password},
      );
    } on DioException catch (e) {
      throw PanelApiException.network(e, _networkMessage(e));
    }
    final token = _extractToken(res.data);
    if (token != null && token.isNotEmpty) return token;
    throw PanelApiException(_messageOf(res.data, res.statusCode) ?? '账号编号或密码不对');
  }

  /// 公告。这个接口不包 status，`data` 在最外层。失败返回 null，调用方留着上次的结果。
  Future<List<Map<String, dynamic>>?> fetchNotices(String token) async {
    try {
      final res = await _dio.get<dynamic>(
        '/api/v1/user/notice/fetch',
        queryParameters: const {'current': 1},
        options: Options(headers: {'auth_data': token, 'Authorization': token}),
      );
      final body = res.data;
      if (body is! Map) return const [];
      final data = body['data'];
      if (data is! List) return const [];
      return [
        for (final row in data)
          if (row is Map) Map<String, dynamic>.from(row),
      ];
    } catch (_) {
      return null;
    }
  }

  /// 当前号有没有付过的订单（status 3 已完成 / 4 已折抵）。
  /// 失败返回 null，调用方当没买过、不拦登录。
  Future<bool?> hasPaidOrder(String token) async {
    try {
      final res = await _dio.get<dynamic>(
        '/api/v1/user/order/fetch',
        options: Options(headers: {'auth_data': token, 'Authorization': token}),
      );
      final body = res.data;
      final list = (body is Map && body['data'] is List) ? body['data'] as List : const [];
      for (final o in list) {
        if (o is! Map) continue;
        final st = o['status'];
        final n = st is num ? st.toInt() : int.tryParse('$st');
        if (n == 3 || n == 4) return true;
      }
      return false;
    } catch (_) {
      return null;
    }
  }

  /// 订阅令牌是不是本面板发的：用当前可用的 API 拉一次订阅，200 且有内容即是
  /// （别家机场的令牌在这里是 403）。用来认「链接域名不在已知名单里」的自家订阅——
  /// 换域靠 feed 不发版，所以导入时不能只靠域名名单判断（2026-09-20）。
  Future<bool> isOwnSubscribeToken(String token) async {
    try {
      final res = await _dio.get<dynamic>(
        '/api/v1/client/subscribe',
        queryParameters: {'token': token},
        options: Options(responseType: ResponseType.plain),
      );
      final body = res.data?.toString().trim() ?? '';
      // 假令牌实测：403 {"status":"fail","message":"token is error",...}
      return res.statusCode == 200 && body.isNotEmpty && !body.contains('"status":"fail"');
    } catch (_) {
      return false;
    }
  }

  void _logCall(String what, Stopwatch sw, Response<dynamic>? res) {
    final host = Uri.tryParse(res?.requestOptions.baseUrl ?? '')?.host ?? '';
    Logger.app.info('$what $host ${sw.elapsedMilliseconds}ms ${res?.statusCode ?? '-'}');
  }

  /// 拉当前账号的订阅地址。需要登录令牌。
  Future<PanelSubscribe> getSubscribe(String token) async {
    final sw = Stopwatch()..start();
    Response<dynamic> res;
    final snapEpoch = _snapshotEpoch;
    try {
      res = await _dio.get<dynamic>(
        '/api/v1/user/getSubscribe',
        options: Options(headers: {'auth_data': token, 'Authorization': token}),
      );
    } on DioException catch (e) {
      _logCall('拉订阅', sw, e.response);
      throw PanelApiException.network(e, _networkMessage(e));
    }
    _logCall('拉订阅', sw, res);
    if (res.statusCode == 401 || res.statusCode == 403) {
      throw PanelApiException('登录已过期，请重新登录', unauthorized: true);
    }
    final data = _dataOf(res.data);
    if (data == null) {
      throw PanelApiException(_messageOf(res.data, res.statusCode) ?? '获取订阅失败');
    }
    var url = (data['subscribe_url'] as String?)?.trim() ?? '';
    final subToken = (data['token'] as String?)?.trim() ?? '';
    if (subToken.isNotEmpty || looksLikeOwnPanelSubscribe(url)) {
      url = buildOwnSubscribeUrl(
        apiBase: PanelApiBase.current,
        token: subToken,
        originalUrl: url,
      );
    }
    if (url.isEmpty) {
      throw PanelApiException('该账号还没有可用套餐，请先在会员中心购买');
    }
    unawaited(_saveSnapshot(data, snapEpoch));
    return PanelSubscribe(
      subscribeUrl: url,
      email: (data['email'] as String?)?.trim(),
      account: _accountOf(data),
    );
  }

  /// 单独拉账号信息（会员页刷新用）。
  Future<PanelAccount> getAccount(String token) async {
    final sw = Stopwatch()..start();
    Response<dynamic> res;
    final snapEpoch = _snapshotEpoch;
    try {
      res = await _dio.get<dynamic>(
        '/api/v1/user/getSubscribe',
        options: Options(headers: {'auth_data': token, 'Authorization': token}),
      );
    } on DioException catch (e) {
      _logCall('读账号', sw, e.response);
      throw PanelApiException.network(e, _networkMessage(e));
    }
    _logCall('读账号', sw, res);
    if (res.statusCode == 401 || res.statusCode == 403) {
      throw PanelApiException('登录已过期，请重新登录', unauthorized: true);
    }
    final data = _dataOf(res.data);
    if (data == null) throw PanelApiException(_messageOf(res.data, res.statusCode) ?? '获取账号信息失败');
    unawaited(_saveSnapshot(data, snapEpoch));
    return _accountOf(data);
  }

  /// 免注册开号失败报一条（体检修复 R7，POST /api/v1/guest/gsl_guest/fail）。以前服务器只记开成功的，
  /// 算不出开号成功率。失败就算了，不影响开号流程。
  static int _guestFailCount = 0;
  Future<void> reportGuestFail(String reason, String appVer) async {
    try {
      await _dio.post<dynamic>('/api/v1/guest/gsl_guest/fail', data: {
        'platform': 'android',
        'app_ver': appVer,
        'try_n': ++_guestFailCount,
        'reason': reason.length > 100 ? reason.substring(0, 100) : reason,
      });
    } catch (_) {}
  }

  // ---- 账号快照（体检修复 A2）：冷启动先显示上次的「剩几天 / 套餐 / 流量」，后台再刷新。----
  // 以前账号只在内存里，每次打开先看「正在读取账号…」，网不好要等 15 秒（Windows 早就有缓存）。
  // 存加密存储；只存界面要显示的字段（白名单）。订阅地址、token、完整 uuid（连节点的凭证）都不存，
  // uuid 只留前 8 位够算账号编号（finecomb 审查 A-3）。
  static const _snapshotKey = 'panel_account_snapshot';
  static const _snapshotStore = FlutterSecureStorage(aOptions: AndroidOptions(encryptedSharedPreferences: true));
  static const _snapshotFields = [
    'email', 'expired_at', 'plan', 'plan_id', 'plan_name', 'device_limit', 'transfer_enable', 'u', 'd',
    'gsl_daily', 'gsl_free_trial', 'gsl_down', 'gsl_isp', 'gsl_trial',
  ];
  // 退出登录时加一：退出前发出、退出后才回来的那次读账号，不能把旧号的快照又写回去。
  static int _snapshotEpoch = 0;

  static Future<void> _saveSnapshot(Map<String, dynamic> data, int epoch) async {
    if (epoch != _snapshotEpoch) return;
    final keep = <String, dynamic>{
      for (final k in _snapshotFields)
        if (data.containsKey(k)) k: data[k],
    };
    final uuid = (data['uuid'] as String?)?.replaceAll('-', '') ?? '';
    if (uuid.length >= 8) keep['uuid'] = uuid.substring(0, 8);
    try {
      await _snapshotStore.write(key: _snapshotKey, value: jsonEncode(keep));
    } catch (_) {}
  }

  /// 上次拉到的账号；没有 / 读不出返回 null。
  Future<PanelAccount?> loadAccountSnapshot() async {
    try {
      final raw = await _snapshotStore.read(key: _snapshotKey);
      if (raw == null || raw.isEmpty) return null;
      final m = jsonDecode(raw);
      return m is Map ? _accountOf(m.cast<String, dynamic>()) : null;
    } catch (_) {
      return null;
    }
  }

  static Future<void> clearAccountSnapshot() async {
    _snapshotEpoch++;
    try {
      await _snapshotStore.delete(key: _snapshotKey);
    } catch (_) {}
  }

  PanelAccount _accountOf(Map<String, dynamic> data) {
    num n(dynamic v) => v is num ? v : num.tryParse('$v') ?? 0;
    final plan = data['plan'];
    final daily = data['gsl_daily'];
    final dailyMap = daily is Map ? daily : null;
    return PanelAccount(
      email: (data['email'] as String?)?.trim(),
      uuid: (data['uuid'] as String?)?.trim(),
      planName: (plan is Map ? plan['name'] as String? : null)?.trim() ?? (data['plan_name'] as String?)?.trim(),
      expiredAt: data['expired_at'] == null ? null : n(data['expired_at']).toInt(),
      transferEnable: n(data['transfer_enable']).toInt(),
      used: (n(data['u']) + n(data['d'])).toInt(),
      deviceLimit: n(data['device_limit']).toInt(),
      dailyKnown: dailyMap != null,
      dailyUsed: dailyMap == null ? 0 : n(dailyMap['used']).toInt(),
      dailyQuota: dailyMap == null ? 0 : n(dailyMap['quota']).toInt(),
      dailyThrottled: dailyMap != null && dailyMap['throttled'] == true,
      dailyThrottleMbps: dailyMap == null ? 0 : n(dailyMap['throttle_mbps']).toInt(),
      dailyTier: dailyMap == null || dailyMap['tier'] is! String ? null : dailyMap['tier'] as String,
      freeTrialFlag: data['gsl_free_trial'] is bool ? data['gsl_free_trial'] as bool : null,
      trialPendingHours: trialPendingHoursOf(data['gsl_trial']),
      paidQuota: dailyMap == null ? 0 : n(dailyMap['paid_quota']).toInt(),
      paidThrottleMbps: dailyMap == null ? 0 : n(dailyMap['paid_throttle_mbps']).toInt(),
      proKnown: dailyMap != null && dailyMap.containsKey('pro_quota'),
      proUsed: dailyMap == null ? 0 : n(dailyMap['pro_used']).toInt(),
      proQuota: dailyMap == null ? 0 : n(dailyMap['pro_quota']).toInt(),
      proThrottled: dailyMap != null && dailyMap['pro_throttled'] == true,
      proThrottleMbps: dailyMap == null ? 0 : n(dailyMap['pro_throttle_mbps']).toInt(),
      downLines: {
        for (final d in (data['gsl_down'] is List ? data['gsl_down'] as List : const []))
          if (d is Map && '${d['name'] ?? ''}'.trim().isNotEmpty) splitNodeName('${d['name']}').name,
      },
      isp: kIspWords.contains(data['gsl_isp']) ? data['gsl_isp'] as String : '',
    );
  }

  /// 发邮箱验证码（注册 / 找回密码用）。
  Future<void> sendEmailCode(String email) async {
    Future<Response<dynamic>> post(String? altcha) {
      return _dio.post<dynamic>(
        '/api/v1/passport/comm/sendEmailVerify',
        data: {
          'email': email.trim(),
          if (altcha != null && altcha.isNotEmpty) 'altcha': altcha,
        },
      );
    }

    Future<void> once(String? altcha) async {
      Response<dynamic> res;
      try {
        res = await post(altcha);
      } on DioException catch (e) {
        throw PanelApiException(_messageOf(e.response?.data, e.response?.statusCode) ?? _networkMessage(e));
      }
      final data = _dataOf(res.data);
      if (data != null || res.statusCode == 200) return;
      throw PanelApiException(_messageOf(res.data, res.statusCode) ?? '验证码发送失败，请稍后再试');
    }

    final answer = await solveAltcha(_dio);
    try {
      await once(answer);
    } on PanelApiException catch (e) {
      if (answer != null && e.message.contains('验证失败')) {
        await once(await solveAltcha(_dio));
        return;
      }
      rethrow;
    }
  }

  /// 首页常用网站那一排被点了：匿名记一次（src=android_quick，跟官网 /sites/ 同一个埋点）。
  /// 服务端按「IP + 网站 + 天」去重算 30 天热度。发不出去不管、不重试。
  Future<void> reportSiteClick(String siteId) async {
    if (!RegExp(r'^[a-z0-9-]{1,32}$').hasMatch(siteId)) return;
    try {
      await _dio.post<dynamic>(
        '/api/v1/guest/gsl_invite/hit',
        data: {'event': 'site_click', 'site': siteId, 'src': 'android_quick'},
      );
    } catch (_) {}
  }

  /// 注册选项（站点是否要邮箱验证 / 是否强制邀请码 / 是否有人机验证）。
  /// 走 guest/comm/config，免登录。出错时返回保守默认（要验证码、不强制邀请、无 recaptcha）。
  Future<({bool emailVerify, bool inviteForce, bool recaptcha})> getRegisterOptions() async {
    try {
      final data = await CommConfig.get();
      bool flag(String k) => data[k] == true || data[k] == 1 || data[k] == '1';
      return (
        emailVerify: data.isEmpty || flag('is_email_verify'),
        inviteForce: flag('is_invite_force'),
        recaptcha: flag('is_recaptcha'),
      );
    } catch (_) {
      return (emailVerify: true, inviteForce: false, recaptcha: false);
    }
  }

  /// 注册新账号。成功返回 auth 令牌（部分站点注册后不直接返回，则由调用方改用登录）。
  Future<String?> register(String email, String password, {String? code, String? inviteCode}) async {
    Response<dynamic> res;
    try {
      res = await _dio.post<dynamic>(
        '/api/v1/passport/auth/register',
        data: {
          'email': email.trim(),
          'password': password,
          if (code != null && code.trim().isNotEmpty) 'email_code': code.trim(),
          if (inviteCode != null && inviteCode.trim().isNotEmpty) 'invite_code': inviteCode.trim(),
        },
      );
    } on DioException catch (e) {
      throw PanelApiException.network(e, _networkMessage(e));
    }
    final token = _extractToken(res.data);
    if (token != null && token.isNotEmpty) return token;
    // 注册成功但没返回令牌：账号已建好，调用方用密码登录一次即可。
    if (_dataOf(res.data) != null || res.statusCode == 200) return null;
    throw PanelApiException(_messageOf(res.data, res.statusCode) ?? '注册失败，请检查信息后重试');
  }

  /// 游客试用开关 / 文案（GslGuest 插件，走 guest/comm/config）。拿不到 gsl_guest 对象
  /// = 服务端没装插件，enabled=false（不走游客，照旧登录页）。
  ///
  /// canBuy = 游客能不能不绑邮箱直接下单（GslGuest 1.1.0 的「允许游客直接购买」）。
  /// 读不到按 false 处理 —— 和老服务端行为一致（购买前先跳绑定页），免得客户端放行
  /// 了服务端却拦着，用户填完支付信息才报错。
  Future<GuestOptions> getGuestOptions() async {
    Map<String, dynamic> data;
    try {
      data = await CommConfig.get();
    } on DioException catch (e) {
      throw PanelApiException.network(e, _networkMessage(e));
    } on CommConfigUnavailable {
      throw PanelApiException('连不上服务器，请检查网络后点重试。如果开着别的 VPN，先关掉它', isNetworkError: true);
    } catch (_) {
      throw PanelApiException('网络请求失败', isNetworkError: true);
    }

    try {
      final g = data['gsl_guest'];
      if (g is! Map) return _guestOptionsOff;
      final enabled = g['enabled'] == true || g['enabled'] == 1 || g['enabled'] == '1';
      final suffix = g['email_suffix'] is String && (g['email_suffix'] as String).isNotEmpty
          ? g['email_suffix'] as String
          : guestEmailSuffix;
      final bonus = g['bind_bonus_text'];
      return (
        enabled: enabled,
        suffix: suffix,
        bindBonusText: bonus is String && bonus.trim().isNotEmpty ? bonus.trim() : null,
        canBuy: g['can_buy'] == true || g['can_buy'] == 1 || g['can_buy'] == '1',
        // 1.3.0：这台服务端开号会回一个抄得下来的密码，也支持免注册号自己设密码。
        selfPassword:
            g['self_password'] == true || g['self_password'] == 1 || g['self_password'] == '1',
      );
    } catch (_) {
      return _guestOptionsOff;
    }
  }

  static const GuestOptions _guestOptionsOff =
      (enabled: false, suffix: guestEmailSuffix, bindBonusText: null, canBuy: false, selfPassword: false);

  /// 免登录的公开节点清单（GslGuest 插件的 catalog）。
  ///
  /// 首页和线路页在「还没开成号」「试用已到期」这两种状态下也得有东西可显示，而这两种
  /// 状态下订阅是空的。只有名字（`地区 | 说明 | 场景`），拿到也连不上；服务端按
  /// machine_id 去重，所以这里拿到的是真实机器数，不是面板里的行数。
  /// 插件没装 / 网络不通 → 空列表，调用方自己降级。
  Future<List<String>> getPublicNodes() async {
    try {
      final res = await _dio.get<dynamic>('/api/v1/guest/gsl_guest/catalog');
      final data = _dataOf(res.data);
      final names = <String>[];
      if (data?['nodes'] case final List raw) {
        for (final n in raw) {
          final name = n is Map ? n['name'] : n;
          if (name is String && name.trim().isNotEmpty) names.add(name.trim());
        }
      }
      return names;
    } catch (_) {
      return const <String>[];
    }
  }

  /// 游客占位邮箱后缀（跟服务端 GslGuest 的 Guest::EMAIL_SUFFIX 一致）。
  static const guestEmailSuffix = '@guest.invalid';

  /// 按设备号开通 / 取回游客号。成功返回 token；这台设备登过正式账号返回 hasAccountMask
  /// （打码邮箱，可能是空串）。失败抛 [PanelApiException]。
  ///
  /// password 只有**这次是新开的号**才有值（GslGuest 1.3.0）：服务端只存哈希，
  /// 取回同一个老号时给不出原文。空不是错误，别拿它判断成功失败。
  ///
  /// onVerify：服务端要先算题（开着别的 VPN、IP 在国外，GslGuest 1.8.2+）、开始算之前调一次，
  /// 首页借它把「正在开通免费试用…」换成「正在进行人机验证」。
  Future<({String? token, String? hasAccountMask, String? hasAccountNo, String? password, bool hasInviter})> guestLogin(
      String deviceId, {String? inviteCode, void Function()? onVerify}) async {
    final sw = Stopwatch()..start();
    // 绝大多数 IP 没被封，服务端不看答案。先不带答案发；只有 400 才算题，再发一次。
    Future<Response<dynamic>> post(String? altcha) {
      return _dio.post<dynamic>(
        '/api/v1/guest/gsl_guest/login',
        data: {
          'device_id': deviceId,
          'platform': 'android',
          if (inviteCode != null && inviteCode.trim().isNotEmpty) 'invite_code': inviteCode.trim(),
          if (altcha != null && altcha.isNotEmpty) 'altcha': altcha,
        },
      );
    }

    // 这个 Dio 把任何 HTTP 状态都当成正常返回，400 不会进 DioException。
    Response<dynamic> res;
    try {
      res = await post(null);
    } on DioException catch (e) {
      _logCall('开号', sw, e.response);
      throw PanelApiException.network(e, _networkMessage(e));
    }
    if (res.statusCode == 400) {
      onVerify?.call();
      final altcha = await solveAltcha(_dio);
      if (altcha != null && altcha.isNotEmpty) {
        try {
          res = await post(altcha);
        } on DioException catch (e) {
          _logCall('开号', sw, e.response);
          throw PanelApiException.network(e, _networkMessage(e));
        }
      }
    }
    _logCall('开号', sw, res);
    final data = _dataOf(res.data);
    if (data?['status'] == 'has_account') {
      final mask = data?['email_mask'];
      // GslGuest 1.8.6 起带这个账号的编号：登录页预填，「输入密码就能登录」才是真的。
      final no = data?['account_no'];
      return (
        token: null,
        hasAccountMask: mask is String ? mask : '',
        hasAccountNo: no is String && no.isNotEmpty ? no : null,
        password: null,
        hasInviter: false,
      );
    }
    final token = _extractToken(res.data);
    if (token != null && token.isNotEmpty) {
      final pw = data?['password'];
      return (
        token: token,
        hasAccountMask: null,
        hasAccountNo: null,
        password: pw is String && pw.isNotEmpty ? pw : null,
        hasInviter: data?['has_inviter'] == true,
      );
    }
    // 这个 Dio 不会因为 5xx 抛异常：面板重启时这里拿到 502，算网络问题（重试），不算服务端拒绝（去注册）。
    throw PanelApiException(
      _messageOf(res.data, res.statusCode) ?? '免注册试用暂时不可用，请注册账号',
      isNetworkError: (res.statusCode ?? 0) == 0 || (res.statusCode ?? 0) >= 500,
      action: res.data is Map && (res.data as Map)['action'] is String ? (res.data as Map)['action'] as String : null,
    );
  }

  Future<({String code, int expiresIn, String accountNo, int used, int limit, bool guest, bool full, int? limitAfterBind})> createPairCode(String token) async {
    final res = await _dio.post<dynamic>(
      '/api/v1/user/gsl_guest/pair',
      data: {'platform': 'android'},
      options: Options(headers: {'auth_data': token, 'Authorization': token}),
    );
    final data = _dataOf(res.data);
    if (data == null || data['code'] == null) {
      throw PanelApiException(_messageOf(res.data, res.statusCode) ?? '暂时发不出配对码，请再试一次');
    }
    num n(dynamic v) => v is num ? v : num.tryParse('$v') ?? 0;
    final devices = data['devices'];
    final rawAfter = data['limit_after_bind'];
    return (
      code: '${data['code']}',
      expiresIn: n(data['expires_in']).toInt(),
      accountNo: '${data['account_no'] ?? ''}',
      used: devices is Map ? n(devices['used']).toInt() : 0,
      limit: devices is Map ? n(devices['limit']).toInt() : 0,
      guest: data['guest'] == true,
      full: data['full'] == true,
      limitAfterBind: rawAfter is num ? rawAfter.toInt() : null,
    );
  }

  Future<String> redeemPairCode(String code, String deviceId) async {
    Response<dynamic> res;
    try {
      res = await _dio.post<dynamic>(
        '/api/v1/guest/gsl_guest/pair/redeem',
        data: {'code': code, 'platform': 'android', 'device_id': deviceId},
      );
    } on DioException catch (e) {
      throw PanelApiException.network(e, _networkMessage(e));
    }
    final token = _extractToken(res.data);
    if (token != null && token.isNotEmpty) return token;
    throw PanelApiException(_messageOf(res.data, res.statusCode) ?? '配对码不对或已过期，在原来那台设备上换一个再试');
  }

  Future<({List<Map<String, dynamic>> devices, int used, int limit})> fetchDevices(String token) async {
    final res = await _dio.get<dynamic>(
      '/api/v1/user/gsl_guest/devices',
      options: Options(headers: {'auth_data': token, 'Authorization': token}),
    );
    final data = _dataOf(res.data) ?? const {};
    num n(dynamic v) => v is num ? v : num.tryParse('$v') ?? 0;
    final raw = data['devices'];
    final list = <Map<String, dynamic>>[];
    if (raw is List) {
      for (final row in raw) {
        if (row is Map) list.add(Map<String, dynamic>.from(row));
      }
    }
    return (devices: list, used: n(data['used']).toInt(), limit: n(data['limit']).toInt());
  }

  Future<({String scanText, String subUrl, String svg})> fetchIphoneQr(String token) async {
    final res = await _dio.get<dynamic>(
      '/api/v1/user/gsl_guest/iphone-qr',
      options: Options(headers: {'auth_data': token, 'Authorization': token}),
    );
    final data = _dataOf(res.data);
    if (data == null) throw PanelApiException(_messageOf(res.data, res.statusCode) ?? '暂时拿不到二维码');
    return (
      scanText: '${data['scan_text'] ?? ''}',
      subUrl: '${data['sub_url'] ?? ''}',
      svg: '${data['svg'] ?? ''}',
    );
  }

  /// 只问「这台设备上是谁」，**不发 token、不开号**（GslGuest 1.3.0 的 probe）。
  ///
  /// 用户主动退出过之后走这条路：既不能偷偷再塞一个免费号给他，也不该像 1.1.40
  /// 那样干脆不问、在首页写一句含糊的「登录后就能连接」。
  ///
  /// ⚠️ 只能在 comm/config 报了 self_password（= 1.3.0+）时调用。老服务端不认
  /// probe，会当成普通开号**真的建一个号**出来。
  /// 返回 kind：'guest' / 'account' / 'none'。
  Future<({String kind, String? accountNo, String? emailMask, String? altAccountNo, String? altEmailMask})>
      probeDevice(String deviceId) async {
    Response<dynamic> res;
    try {
      res = await _dio.post<dynamic>(
        '/api/v1/guest/gsl_guest/login',
        data: {
          'device_id': deviceId,
          'platform': 'android',
          'probe': true,
        },
      );
    } on DioException catch (e) {
      throw PanelApiException.network(e, _networkMessage(e));
    }
    final data = _dataOf(res.data);
    final status = data?['status'];
    String? s(String k) {
      final v = data?[k];
      return v is String && v.isNotEmpty ? v : null;
    }

    if (status == 'has_account') {
      return (
        kind: 'account',
        // GslGuest 1.8.6 起：这个正式账号的账号编号（登录页预填）。老服务端没有 = null。
        accountNo: s('account_no'),
        emailMask: s('email_mask') ?? '',
        altAccountNo: s('also_account_no'),
        altEmailMask: null,
      );
    }
    if (status == 'guest') {
      return (
        kind: 'guest',
        accountNo: s('account_no'),
        emailMask: null,
        altAccountNo: null,
        altEmailMask: s('also_email_mask'),
      );
    }
    if (status == 'none') {
      return (kind: 'none', accountNo: null, emailMask: null, altAccountNo: null, altEmailMask: null);
    }
    // 老服务端把 probe 当成普通开号了（不该走到这儿，调用方应该先看 self_password）。
    throw PanelApiException('这台服务端还不支持');
  }

  /// 已经开好的号补填一次邀请码。已经有推荐人时服务端不覆盖。
  /// 返回 ok / already。失败抛 [PanelApiException]。
  Future<String> setGuestInvite(String token, String inviteCode) async {
    Response<dynamic> res;
    try {
      res = await _dio.post<dynamic>(
        '/api/v1/user/gsl_guest/invite',
        data: {'invite_code': inviteCode.trim()},
        options: Options(headers: {'auth_data': token, 'Authorization': token}),
      );
    } on DioException catch (e) {
      throw PanelApiException.network(e, _networkMessage(e));
    }
    if (res.statusCode != null && res.statusCode! >= 400) {
      throw PanelApiException(_messageOf(res.data, res.statusCode) ?? '邀请码没记上，稍后再试');
    }
    final data = _dataOf(res.data);
    final status = data?['status'];
    return status is String ? status : 'ok';
  }

  /// 关注 TG 频道送时长（GslStats 1.19.0）。state：open 能领 / claimed 领过 / forever 长期有效 / off 关着；
  /// tg = tg:// 直接拉起机器人（带专属码），page = 官网 /gift/ 中转页（没装 Telegram 时用）。查不到返回 null。
  Future<Map<String, dynamic>?> fetchTgGift(String token) async {
    try {
      final res = await _dio.get<dynamic>(
        '/api/v1/user/gsl_tg/gift',
        queryParameters: {'source': 'app'},
        options: Options(headers: {'auth_data': token, 'Authorization': token}),
      );
      if (res.statusCode != null && res.statusCode! >= 400) return null;
      return _dataOf(res.data);
    } catch (_) {
      return null;
    }
  }

  /// 免注册号自己设密码（GslGuest 1.3.0）。账号编号 + 这个密码 = 换手机也能登回来。
  /// 成功返回 null，失败抛 [PanelApiException]。
  Future<void> setGuestPassword(String token, String password) async {
    Response<dynamic> res;
    try {
      res = await _dio.post<dynamic>(
        '/api/v1/user/gsl_guest/set-password',
        data: {'password': password},
        options: Options(headers: {'auth_data': token, 'Authorization': token}),
      );
    } on DioException catch (e) {
      throw PanelApiException.network(e, _networkMessage(e));
    }
    if (res.statusCode == 401) throw PanelApiException('登录已过期，请重新打开 App', unauthorized: true);
    if (res.statusCode != null && res.statusCode! >= 400) {
      throw PanelApiException(_messageOf(res.data, res.statusCode) ?? '设置密码失败，请稍后再试');
    }
  }

  /// 游客绑定邮箱：原账号改成这个邮箱 + 密码，token 和订阅都不变。返回绑定后的邮箱。
  Future<String> bindGuest(
    String token,
    String email,
    String password, {
    String? code,
    String? inviteCode,
  }) async {
    Response<dynamic> res;
    try {
      res = await _dio.post<dynamic>(
        '/api/v1/user/gsl_guest/bind',
        data: {
          'email': email.trim(),
          'password': password,
          if (code != null && code.trim().isNotEmpty) 'email_code': code.trim(),
          if (inviteCode != null && inviteCode.trim().isNotEmpty) 'invite_code': inviteCode.trim(),
        },
        options: Options(headers: {'auth_data': token, 'Authorization': token}),
      );
    } on DioException catch (e) {
      throw PanelApiException.network(e, _networkMessage(e));
    }
    if (res.statusCode == 401) throw PanelApiException('登录已过期，请重新打开 App', unauthorized: true);
    final data = _dataOf(res.data);
    final bound = data?['email'];
    if (res.statusCode == 200 && bound is String && bound.isNotEmpty) return bound;
    throw PanelApiException(_messageOf(res.data, res.statusCode) ?? '注册失败，请稍后再试');
  }

  /// 用邮箱验证码重置密码。
  Future<void> resetPassword(String email, String newPassword, String code) async {
    Response<dynamic> res;
    try {
      res = await _dio.post<dynamic>(
        '/api/v1/passport/auth/forget',
        data: {'email': email.trim(), 'password': newPassword, 'email_code': code.trim()},
      );
    } on DioException catch (e) {
      throw PanelApiException.network(e, _networkMessage(e));
    }
    if (_dataOf(res.data) != null || res.statusCode == 200) return;
    throw PanelApiException(_messageOf(res.data, res.statusCode) ?? '重置失败，请检查验证码');
  }

  /// 拿邀请码（没有就让面板生成一个），返回 (code, link)。
  Future<({String code, String link})> getInvite(String token) async {
    final opt = Options(headers: {'auth_data': token, 'Authorization': token});
    String? readCode(dynamic body) {
      final data = _dataOf(body);
      final codes = data?['codes'];
      if (codes is List) {
        for (final c in codes) {
          if (c is Map && c['code'] is String && (c['code'] as String).isNotEmpty) {
            return c['code'] as String;
          }
        }
      }
      return null;
    }

    Response<dynamic> res;
    try {
      res = await _dio.get<dynamic>('/api/v1/user/invite/fetch', options: opt);
      if (res.statusCode == 401 || res.statusCode == 403) {
        throw PanelApiException('登录已过期，请重新登录', unauthorized: true);
      }
      var code = readCode(res.data);
      if (code == null) {
        await _dio.get<dynamic>('/api/v1/user/invite/save', options: opt);
        res = await _dio.get<dynamic>('/api/v1/user/invite/fetch', options: opt);
        code = readCode(res.data);
      }
      if (code == null) throw PanelApiException('面板没有返回邀请码');
      final texts = await getInviteTexts();
      final link = _inviteLinkFromTemplate(texts.linkTemplate, code);
      return (code: code, link: link);
    } on DioException catch (e) {
      throw PanelApiException.network(e, _networkMessage(e));
    }
  }

  /// 拉服务器下发的邀请文案（GslInviteBonus 插件，走 guest/comm/config，免登录）。
  /// 改文案不用发客户端版本。`bonus` = 奖励额度（如「3 天会员时长」），`share` = 分享文案
  /// 模板（含 {bonus} / {link} 占位符）。1.53.0 起还有：好友第一次付款满 `paidMinYuan` 送
  /// 邀请人 `paidBonus`，每满 `goal` 位再送 `goalText`，返利比例 `rate`。拿不到对应项为 null。
  Future<InviteTexts> getInviteTexts() async {
    try {
      final data = await CommConfig.get();
      final gsl = data['gsl_invite'];
      final Map<String, dynamic>? obj = gsl is Map ? gsl.cast<String, dynamic>() : null;
      String? pick(String k) {
        final raw = (obj != null ? obj[k] : null) ?? data[k];
        return (raw is String && raw.trim().isNotEmpty) ? raw.trim() : null;
      }

      int? count(String k) {
        final raw = obj != null ? obj[k] : null;
        final v = raw is num ? raw.toInt() : int.tryParse('${raw ?? ''}');
        return (v != null && v > 0) ? v : null;
      }

      return (
        bonus: pick('bonus_text'),
        share: pick('share_text'),
        linkTemplate: pick('invite_link_template'),
        paidBonus: pick('paid_bonus_text'),
        goalText: pick('goal_text'),
        goal: count('goal'),
        paidMinYuan: count('paid_min_yuan'),
        rate: count('rate'),
      );
    } catch (_) {
      return (bonus: null, share: null, linkTemplate: null, paidBonus: null, goalText: null, goal: null, paidMinYuan: null, rate: null);
    }
  }

  static String _inviteLinkFromTemplate(String? template, String code) {
    if (template != null && template.contains('{code}')) {
      final origin = Constants.panelInviteUrl.replaceAll(RegExp(r'/i/?$'), '').replaceAll(RegExp(r'/+$'), '');
      return template.replaceAll('{app_url}', origin).replaceAll('{code}', code);
    }
    final base = Constants.panelInviteUrl.replaceAll(RegExp(r'/+$'), '');
    return '$base/?c=$code';
  }

  /// 「我邀请的人」列表（邮箱打码）。需要登录令牌。`paidCount` = 算进「每满 N 位送」的付费好友数。
  Future<({List<InviteReferral> items, int total, int paidCount})> getReferrals(String token, {int page = 1}) async {
    Response<dynamic> res;
    try {
      res = await _dio.get<dynamic>(
        '/api/v1/user/gsl_invite/referrals',
        queryParameters: {'page': page},
        options: Options(headers: {'auth_data': token, 'Authorization': token}),
      );
    } on DioException catch (e) {
      throw PanelApiException.network(e, _networkMessage(e));
    }
    if (res.statusCode == 401 || res.statusCode == 403) {
      throw PanelApiException('登录已过期，请重新登录', unauthorized: true);
    }
    final body = res.data;
    final rawList = (body is Map && body['data'] is List) ? body['data'] as List<dynamic> : const [];
    final items = rawList
        .whereType<Map>()
        .map((m) => InviteReferral.fromJson(m.cast<String, dynamic>()))
        .toList();
    final total = (body is Map && body['total'] is num) ? (body['total'] as num).toInt() : items.length;
    final paidCount = (body is Map && body['paid_count'] is num) ? (body['paid_count'] as num).toInt() : 0;
    return (items: items, total: total, paidCount: paidCount);
  }

  /// 设备闸：连接前 / 连接中 claim 一次稳定设备 ID（见 VPN 仓库
  /// `tools/device-gate/gate.py`）。
  ///
  /// 返回 null = 闸联系不上（网络问题 / 404 / 5xx）——闸是 fail-open，调用方
  /// 应该照常放行连接，只是这次不计入设备数。
  /// 抛 [PanelApiException]：`unauthorized=true`（401）= 登录已过期，不要连；
  /// 否则（403）= 设备数已满，[PanelApiException.message] 是闸给用户看的原话，
  /// 同样不要连。
  Future<({int used, int limit})?> claimDevice(
    String token,
    String deviceId, {
    required bool connected,
  }) async {
    final base = await _deviceGateBase();
    if (base == null) return null;
    Response<dynamic> res;
    try {
      res = await _dio.post<dynamic>(
        '$base/claim',
        data: {'device_id': deviceId, 'platform': 'android', 'connected': connected},
        options: Options(headers: {'auth_data': token, 'Authorization': token}),
      );
    } on DioException catch (_) {
      return null;
    }
    if (res.statusCode == 200) {
      final data = res.data;
      final used = data is Map ? (num.tryParse('${data['used']}') ?? 0).toInt() : 0;
      final limit = data is Map ? (num.tryParse('${data['limit']}') ?? 0).toInt() : 0;
      return (used: used, limit: limit);
    }
    if (res.statusCode == 401) {
      throw PanelApiException(_messageOf(res.data, res.statusCode) ?? '登录已过期，请重新登录', unauthorized: true);
    }
    if (res.statusCode == 403) {
      throw PanelApiException(_messageOf(res.data, res.statusCode) ?? '设备数已满（按电脑/手机计，不是按宽带）');
    }
    // 400（缺字段，理论上不会发生）/ 404（这套 www 还没配闸）/ 5xx：不是网关的
    // 决定性拒绝，fail-open，别拦用户连接。
    return null;
  }

  /// 设备闸地址。优先用后台 `comm/config` 下发的显式 `device_api`（不用猜，
  /// 不用假设技术域也部署了闸）；没配置就退回旧算法：取当前 API 域名的登记域
  /// （eTLD+1，只取最后两截——买新域名别选 `.com.cn` / `.co.uk` 这类复合后缀），
  /// 拼 `https://www.{登记域}/dengta/device`。和 Windows
  /// `XboardControlPlane::RegistrableDomain` / `applyDerivedSiblings` 是同一条
  /// 兜底算法，两边对得上。
  ///
  /// 用 `PanelApiBase.resolve()` 而不是 `_dio.options.baseUrl`：后者是这个
  /// `PanelApi` 实例构造那一刻的快照——如果 `PanelApi()` 在探活完成之前就
  /// 建好了（拦截器只改每次请求的 `RequestOptions`，不会回写 `_dio.options`），
  /// 快照就可能还是打包默认域名，闸请求会打去一个过期地址。`resolve()` 拿的
  /// 是当前真正生效的地址，必要时会顺带触发一次探活。
  Future<String?> _deviceGateBase() async {
    await RemoteSiteConfig.ensureLoaded();
    if (RemoteSiteConfig.deviceApi != null) return RemoteSiteConfig.deviceApi;
    final host = Uri.tryParse(await PanelApiBase.resolve())?.host;
    if (host == null || host.isEmpty) return null;
    final labels = host.split('.');
    final sld = labels.length >= 2 ? labels.sublist(labels.length - 2).join('.') : host;
    return 'https://www.$sld/dengta/device';
  }

  // --- helpers ---

  String? _extractToken(dynamic body) {
    final data = _dataOf(body);
    return _str(data?['auth_data']) ??
        _str(data?['token']) ??
        _str((body is Map) ? body['auth_data'] : null) ??
        _str((body is Map) ? body['token'] : null);
  }

  Map<String, dynamic>? _dataOf(dynamic body) {
    if (body is Map && body['data'] is Map) {
      return (body['data'] as Map).cast<String, dynamic>();
    }
    return null;
  }

  String? _messageOf(dynamic body, [int? statusCode]) {
    if (body is Map) {
      final m = body['message'] ?? body['error'];
      if (m is String && m.trim().isNotEmpty) {
        final t = m.trim();
        if (t.toLowerCase().startsWith('too many attempts')) return '操作太频繁，等一分钟再试';
        return t;
      }
    }
    if (statusCode == 429) return '操作太频繁，等一分钟再试';
    return null;
  }

  String? _str(dynamic v) => (v is String && v.isNotEmpty) ? v : null;

  String _networkMessage(DioException e) {
    if (e.response?.statusCode == 429) {
      final m = _messageOf(e.response?.data);
      if (m != null) return m;
      return '操作太频繁，等一分钟再试';
    }
    switch (e.type) {
      case DioExceptionType.connectionTimeout:
      case DioExceptionType.sendTimeout:
      case DioExceptionType.receiveTimeout:
        return '连接超时，请检查网络后重试';
      default:
        return '无法连接服务器，请检查网络';
    }
  }
}

class PanelSubscribe {
  const PanelSubscribe({required this.subscribeUrl, this.email, this.account});
  final String subscribeUrl;
  final String? email;
  final PanelAccount? account;
}

/// 每日高速额度。整数不带小数（30 GB），否则留一位（12.4 GB）。
String formatDailyAmount(int bytes) {
  if (bytes <= 0) return '0 GB';
  final gb = bytes / 1073741824;
  final value = gb >= 1 ? gb : bytes / 1048576;
  final unit = gb >= 1 ? 'GB' : 'MB';
  final text = value.toStringAsFixed(1);
  final shown = text.endsWith('.0') ? text.substring(0, text.length - 2) : text;
  return '$shown $unit';
}

/// getSubscribe 的 gsl_trial：试用还没开始算时给试用小时数（没写按 12），已经在算 / 不是试用给 0。
int trialPendingHoursOf(Object? raw) {
  if (raw is! Map || raw['pending'] != true) return 0;
  final h = raw['hours'];
  final hours = h is num ? h.toInt() : int.tryParse('$h') ?? 0;
  return hours > 0 ? hours : 12;
}

class PanelAccount {
  const PanelAccount({
    this.email,
    this.uuid,
    this.planName,
    this.expiredAt,
    this.transferEnable = 0,
    this.used = 0,
    this.deviceLimit = 0,
    this.dailyKnown = false,
    this.dailyUsed = 0,
    this.dailyQuota = 0,
    this.dailyThrottled = false,
    this.dailyThrottleMbps = 0,
    this.dailyTier,
    this.freeTrialFlag,
    this.trialPendingHours = 0,
    this.paidQuota = 0,
    this.paidThrottleMbps = 0,
    this.proKnown = false,
    this.proUsed = 0,
    this.proQuota = 0,
    this.proThrottled = false,
    this.proThrottleMbps = 0,
    this.downLines = const {},
    this.isp = '',
  });

  final String? email;

  /// 面板用户 UUID（`getSubscribe` 返回的 `uuid`）。**不是**订阅 token，可以给用户看。
  /// 拿它的前 8 位做「账号编号」，见 [accountNo]。
  final String? uuid;
  final String? planName;
  final int? expiredAt; // unix 秒；null = 长期有效
  final int transferEnable; // 总流量字节
  final int used; // 已用字节
  final int deviceLimit; // 0 = 不限

  /// getSubscribe 的 gsl_daily。没有这个字段时 dailyKnown 为 false，界面不显示。
  final bool dailyKnown;
  final int dailyUsed;
  final int dailyQuota;
  final bool dailyThrottled;
  final int dailyThrottleMbps;

  /// gsl_daily.tier：trial / paid。老服务端没有就是 null。
  final String? dailyTier;

  /// GslGuest 1.9.0 gsl_free_trial：还在免费试用（免注册号 + 体验套餐）。老插件没给 = null。
  final bool? freeTrialFlag;

  /// GslInviteBonus 1.55.0 gsl_trial.pending：邮箱号的试用还没开始算（第一次连上才算），给的是试用时长。
  /// 这时服务器的到期时间是「要是现在开始能用到哪」，界面不倒计时（跟 Windows remainingLabel 一样）。0 = 已经在算。
  final int trialPendingHours;
  final int paidQuota;
  final int paidThrottleMbps;
  final bool proKnown;
  final int proUsed;
  final int proQuota;
  final bool proThrottled;
  final int proThrottleMbps;

  /// getSubscribe 的 gsl_down：服务端判为「维修中」的线路名（splitNodeName 的 name，跟线路页、
  /// preferredLineName 同一种名字）。列表标「维修中」、点了不让连（docs/计划/节点离线-维修中.md，两端统一）。
  final Set<String> downLines;

  bool isLineDown(String name) => name.isNotEmpty && downLines.contains(name);

  /// getSubscribe 的 gsl_isp：这个号是哪家宽带，「电信」「联通」「移动」或空（认不出 / 老服务端）。
  /// 线路页给这家的 LOGO 加橙圈、顶上提示一句、同国家里适合的排前面（计划书第九节，两端统一）。
  final String isp;

  bool get lifetime => expiredAt == null || expiredAt == 0;

  /// 离到期还有几秒（长期有效 = null，已过期是负数）。
  int? secsLeft([DateTime? now]) =>
      lifetime ? null : expiredAt! - (now ?? DateTime.now()).millisecondsSinceEpoch ~/ 1000;

  /// 还剩几天：往上取整，跟服务器（GslShop Tiers.php days_left）和 Windows 同一个算法。
  /// 长期有效 = null，已过期 = 0。所有「还剩 N 天」都用它。
  int? daysLeft([DateTime? now]) {
    final secs = secsLeft(now);
    return secs == null ? null : (secs <= 0 ? 0 : (secs + 86399) ~/ 86400);
  }

  /// 到期那天「2026-11-09」（长期有效 = 空）。
  String get expiryDay {
    if (lifetime || expiredAt == null || expiredAt! <= 0) return '';
    final d = DateTime.fromMillisecondsSinceEpoch(expiredAt! * 1000);
    return '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';
  }

  /// ≥1 天「N 天」；不足 1 天「X 小时 Y 分」；不足 1 小时「N 分钟」（最少 1）。
  /// 长期或已经到期返回 null。
  String? remainingClock([DateTime? now]) {
    final secs = secsLeft(now);
    if (secs == null || secs <= 0) return null;
    if (secs >= 86400) return '${daysLeft(now)} 天';
    if (secs >= 3600) {
      final hours = secs ~/ 3600;
      final minutes = (secs % 3600) ~/ 60;
      return '$hours 小时 $minutes 分';
    }
    final minutes = secs ~/ 60;
    return '${minutes < 1 ? 1 : minutes} 分钟';
  }
  int get remainingBytes => (transferEnable - used).clamp(0, transferEnable);

  /// 2026-09-19 起全部套餐不限流量：Xboard 没有真正的不限（0 = 没流量），后台用
  /// ≥1000G 的大额度代替。≥ 这个数一律按不限显示、不画条、不提醒。
  static const int unlimitedBytes = 1000 * 1024 * 1024 * 1024;
  bool get unlimitedQuota => transferEnable <= 0 || transferEnable >= unlimitedBytes;

  /// 连接轨迹「账号原因」归类用的状态标记（跟 Windows 客户端 accountStateSlug 一致）：
  /// ok / traffic_exhausted / expired / no_plan。
  String get stateSlug {
    if (transferEnable > 0 && used >= transferEnable) return 'traffic_exhausted';
    final exp = expiredAt;
    if (exp != null && exp > 0 && DateTime.now().millisecondsSinceEpoch >= exp * 1000) {
      return 'expired';
    }
    final noPlan = (planName == null || planName!.trim().isEmpty) &&
        transferEnable <= 0 &&
        (exp == null || exp == 0);
    return noPlan ? 'no_plan' : 'ok';
  }

  /// 流量用完 / 会员到期 —— 连不上是账号原因，不是节点问题。
  bool get exhausted {
    final s = stateSlug;
    return s == 'traffic_exhausted' || s == 'expired';
  }
}

class PanelApiException implements Exception {
  PanelApiException(this.message, {this.unauthorized = false, this.isNetworkError = false, this.action});

  /// 请求没到服务端（没有响应）或服务端 5xx：算网络问题，界面上给「重试」而不是「去注册」。
  PanelApiException.network(DioException e, String message)
      : this(message, isNetworkError: (e.response?.statusCode ?? 0) == 0 || (e.response?.statusCode ?? 0) >= 500);
  final String message;
  final bool unauthorized;
  final bool isNetworkError;

  /// 服务端建议的主按钮（GslGuest 1.7.4 起开号被拒时带）：'retry' = 用户自己能解决（比如关掉别的 VPN）
  /// 后重试；'register' = 只能去注册。老服务端不带，为 null。
  final String? action;
  @override
  String toString() => message;
}
