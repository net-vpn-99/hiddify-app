import 'package:freezed_annotation/freezed_annotation.dart';
import 'package:hiddify/core/model/environment.dart';

part 'remote_version_entity.freezed.dart';

@Freezed()
class RemoteVersionEntity with _$RemoteVersionEntity {
  const RemoteVersionEntity._();

  const factory RemoteVersionEntity({
    required String version,
    required String buildNumber,
    required String releaseTag,
    required bool preRelease,
    required String url,
    required DateTime publishedAt,
    required Environment flavor,
    // OneRay: 直接下载地址（自建 releases.json 的 assets[].browser_download_url）
    String? apkUrl,
    // OneRay: APK 的 sha256（releases.json 的 assets[].sha256），下载后校验
    String? apkSha256,
    // OneRay: 强制更新 —— releases.json 里 "mandatory": true，弹窗不可关闭
    @Default(false) bool mandatory,
  }) = _RemoteVersionEntity;

  String get presentVersion => flavor == Environment.prod ? version : "$version ${flavor.name}";
}
