import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

abstract class Constants {
  static const appName = "光速雷达";
  // 占位名。真域名到手后只改这一处。中转名字不进安装包，只走指针 / feed。
  static const brandDomain = "BRAND.com";
  static const techDomain = "TECH.com";
  static const panelApiBase = "https://api-hk.TECH.com";
  static const ossPointerUrls = [
    "https://api-hk.TECH.com/rules/d9b21c47e0a8f315.txt",
    "https://www.BRAND.com/dengta/d9b21c47e0a8f315.txt",
  ];
  static const panelApiFallbacks = [
    "https://api-hk.TECH.com",
    "https://api.BRAND.com",
  ];
  static const panelRegisterUrl = "https://www.BRAND.com/account/";
  static const panelForgotUrl = "https://www.BRAND.com/account/";
  static const panelPlanUrl = "https://www.BRAND.com/account/";
  static const panelProfileUrl = "https://www.BRAND.com/account/";
  static const panelInviteUrl = "https://www.BRAND.com/i/";
  static const websiteUrl = "https://www.BRAND.com/";
  static const supportPageUrl = "https://www.BRAND.com/support.html";
  static const iosPageUrl = "https://www.BRAND.com/ios/";

  static const githubUrl = "https://www.BRAND.com/help.html";
  static const licenseUrl = "https://www.BRAND.com/help.html";
  static const faqUrl = "https://www.BRAND.com/help.html";
  static const releasesJsonUrls = [
    "https://dl.TECH.com/dengta/android/releases.json",
    "https://www.BRAND.com/dengta/android/releases.json",
  ];
  static const githubReleasesApiUrl = "https://dl.TECH.com/dengta/android/releases.json";
  static const githubLatestReleaseUrl = "https://www.BRAND.com/";
  static const appCastUrl = "https://www.BRAND.com/oneray/android/appcast.xml";
  static const telegramChannelUrl = "https://t.me/+LQ-pvMvK4ClkNzFk";
  static const statusPageUrl = "https://status.BRAND.com/";
  static const kfBase = "https://kf.BRAND.com";
  static const privacyPolicyUrl = "https://www.BRAND.com/help.html";
  static const termsAndConditionsUrl = "https://www.BRAND.com/help.html";
  static const endpointEpoch = 20261004;
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
