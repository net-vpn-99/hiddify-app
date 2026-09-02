import 'package:freezed_annotation/freezed_annotation.dart';
import 'package:hiddify/core/model/environment.dart';

part 'app_info_entity.freezed.dart';

@freezed
class AppInfoEntity with _$AppInfoEntity {
  const AppInfoEntity._();

  const factory AppInfoEntity({
    required String name,
    required String version,
    required String buildNumber,
    required Release release,
    required String operatingSystem,
    required String operatingSystemVersion,
    required Environment environment,
  }) = _AppInfoEntity;

  // OneRay: 不含 "sing-box" / "clash" —— 否则 Xboard 订阅返回完整 sing-box 模板，
  // hiddify-core 提取不出节点会崩。用 v2ray token 让它返回 vless:// 列表，core 自己套模板。
  String get userAgent => "OneRay/$version ($operatingSystem) v2ray";

  String get presentVersion => environment == Environment.prod ? version : "$version ${environment.name}";

  /// formats app info for sharing
  String format() =>
      '''
$name v$version ($buildNumber) [${environment.name}]
${release.name} release
$operatingSystem [$operatingSystemVersion]''';
}
