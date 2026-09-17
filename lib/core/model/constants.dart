import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

abstract class Constants {
  static const appName = "光速";
  // OneRay: 会员系统 API（登录 / 拉订阅），对接 Xboard，与桌面版同一套接口
  static const panelApiBase = "https://api-hk.inkspindle.com";
  // 自有指针在前，第三方阿里 OSS 只当救援。跟 Windows panel.json ossPointerUrls 同一份。
  static const ossPointerUrls = [
    "https://api-hk.inkspindle.com/rules/d9b21c47e0a8f315.txt",
    "https://www.gsldone.com/dengta/d9b21c47e0a8f315.txt",
    "https://surrr.oss-cn-hangzhou.aliyuncs.com/f20025155414474.txt",
  ];
  static const panelApiFallbacks = [
    "https://api-hk.inkspindle.com",
    "https://api.gsldone.com",
    "https://api.inkspindle.com",
    "https://api.guangsuleida.com",
  ];
  // Xboard 会员前台已全部 404，浏览器入口走官网会员中心。
  static const panelRegisterUrl = "https://www.gsldone.com/account/";
  static const panelForgotUrl = "https://www.gsldone.com/account/";
  static const panelPlanUrl = "https://www.gsldone.com/account/"; // 续费/购买
  static const panelProfileUrl = "https://www.gsldone.com/account/"; // 改密码
  static const panelInviteUrl = "https://www.gsldone.com/i/"; // 邀请好友

  static const githubUrl = "https://www.gsldone.com/help.html";
  static const licenseUrl = "https://www.gsldone.com/help.html";
  // OneRay: 「我的 → 帮助与客服 → 常见问题」跳这里（官网帮助页）。
  static const faqUrl = "https://www.gsldone.com/help.html";
  // OneRay: 更新清单。主 = 搬瓦工中转直连（快、抗封），备 = 香港源站（CF）。逐个试。
  static const releasesJsonUrls = [
    // dl.inkspindle.com 是同一台中转机换的非实名域名（2026-09-16），dl2.meadowfoundry.com
    // 留着当过渡期候选。**这个域名下所有路径都要带 /dengta/ 前缀**——它跟旧 dl2 不是
    // 同一套 Caddy 配置，没有 dl2 那种 strip_prefix，第一版少写了这个前缀，实测 404。
    "https://dl.inkspindle.com/dengta/android/releases.json",
    "https://dl2.meadowfoundry.com/android/releases.json",
    "https://www.gsldone.com/dengta/android/releases.json",
    "https://www.guangsuleida.com/dengta/android/releases.json",
  ];
  // 兼容旧字段名，代码里没人读了（搜过 app_update_repository 没有引用），留着不删只是保险。
  static const githubReleasesApiUrl = "https://dl.inkspindle.com/android/releases.json";
  static const githubLatestReleaseUrl = "https://www.gsldone.com/";
  static const appCastUrl = "https://www.gsldone.com/oneray/android/appcast.xml";
  static const telegramChannelUrl = "https://t.me/+LQ-pvMvK4ClkNzFk";
  static const statusPageUrl = "https://gsl-status.guangsu-970.workers.dev/";
  static const privacyPolicyUrl = "https://www.gsldone.com/help.html";
  static const termsAndConditionsUrl = "https://www.gsldone.com/help.html";
  static const cfWarpPrivacyPolicy = "https://www.cloudflare.com/application/privacypolicy/";
  static const cfWarpTermsOfService = "https://www.cloudflare.com/application/terms/";
}

const kAnimationDuration = Duration(milliseconds: 250);

abstract class AddProfileModalConst {
  static const fixBtnsGap = 16.0;
  static const fixBtnsGapCount = 4;
  static const fixBtnsItemCount = 3;
  static const navBarGap = 16.0;
  static const navBarBottomGap = 4.0;
  //switch default height
  static const navBarcontentHeight = 32.0;
  static const navBarHeight = navBarGap + navBarBottomGap + navBarcontentHeight;
}

abstract class AlertDialogConst {
  static const minWidth = 280.0;
  static const maxWidth = 560.0;
  static const boxConstraints = BoxConstraints(minWidth: minWidth, maxWidth: maxWidth);
}

abstract class BottomSheetConst {
  static const maxWidth = 456.0;
  static const boxConstraints = BoxConstraints(maxWidth: maxWidth);
  static const borderRadius = BorderRadius.vertical(top: Radius.circular(32));
}

abstract class ProfileTileConst {
  static const radius = Radius.circular(16);
  static const cardBorderRadius = BorderRadius.all(radius);
  static const borderRadiusRight = BorderRadius.horizontal(right: radius);
  static const borderRadiusLeft = BorderRadius.horizontal(left: radius);
  static BorderRadius startBorderRadius(TextDirection direction) =>
      direction == TextDirection.ltr ? borderRadiusLeft : borderRadiusRight;
  static BorderRadius endBorderRadius(TextDirection direction) =>
      direction == TextDirection.ltr ? borderRadiusRight : borderRadiusLeft;
}

abstract class IntroConst {
  static const maxwidth = 620;
  static const termsAndConditionsKey = 'terms-and-conditions';
  static const githubKey = 'github';
  static const licenseKey = 'license';
  static const url = <String, String>{IntroConst.termsAndConditionsKey: Constants.termsAndConditionsUrl, IntroConst.githubKey: Constants.githubUrl, IntroConst.licenseKey: Constants.licenseUrl};
}

abstract class WarpConst {
  static const warpAccountId = 'warp-account-id';
  static const warpAccessToken = "warp-access-token";
  static const warpConsentGiven = "warp-consent-given";
  static const warpTermsOfServiceKey = 'warp-terms-of-service';
  static const warpPrivacyPolicyKey = 'warp-privacy-policy';
  static const url = <String, String>{WarpConst.warpTermsOfServiceKey: Constants.cfWarpTermsOfService, WarpConst.warpPrivacyPolicyKey: Constants.cfWarpPrivacyPolicy};
}

abstract class KeyboardConst {
  static final allArrows = {LogicalKeyboardKey.arrowUp, LogicalKeyboardKey.arrowDown, LogicalKeyboardKey.arrowLeft, LogicalKeyboardKey.arrowRight};
  static final horizontalArrows = {LogicalKeyboardKey.arrowLeft, LogicalKeyboardKey.arrowRight};
  static final verticalArrows = {LogicalKeyboardKey.arrowUp, LogicalKeyboardKey.arrowDown};
  static final select = {LogicalKeyboardKey.select, LogicalKeyboardKey.enter, LogicalKeyboardKey.tab};
}
