import 'package:dartx/dartx.dart';
import 'package:hiddify/core/model/environment.dart';
import 'package:hiddify/features/app_update/model/remote_version_entity.dart';

abstract class GithubReleaseParser {
  static RemoteVersionEntity parse(Map<String, dynamic> json) {
    final fullTag = json['tag_name'] as String;
    final fullVersion = fullTag.removePrefix("v").split("-").first.split("+");
    var version = fullVersion.first;
    var buildNumber = fullVersion.elementAtOrElse(1, (index) => "");
    var flavor = Environment.prod;
    for (final env in Environment.values) {
      final suffix = ".${env.name}";
      if (version.endsWith(suffix)) {
        version = version.removeSuffix(suffix);
        flavor = env;
        break;
      } else if (buildNumber.endsWith(suffix)) {
        buildNumber = buildNumber.removeSuffix(suffix);
        flavor = env;
        break;
      }
    }
    final preRelease = json["prerelease"] as bool;
    final publishedAt = DateTime.parse(json["published_at"] as String);

    // OneRay: 挑 arm64 的 apk（没有就退回第一个 .apk）
    String? apkUrl;
    String? apkSha256;
    List<String> apkMirrors = const [];
    if (json["assets"] is List) {
      final assets = (json["assets"] as List).whereType<Map<String, dynamic>>().where(
            (a) => (a["name"] as String? ?? "").toLowerCase().endsWith(".apk"),
          );
      final arm64 = assets.firstOrNullWhere((a) => (a["name"] as String).toLowerCase().contains("arm64"));
      final chosen = arm64 ?? assets.firstOrNull;
      apkUrl = chosen?["browser_download_url"] as String?;
      apkSha256 = chosen?["sha256"] as String?;
      if (chosen?["mirrors"] is List) {
        apkMirrors = (chosen!["mirrors"] as List).whereType<String>().toList();
      }
    }

    return RemoteVersionEntity(
      version: version,
      buildNumber: buildNumber,
      releaseTag: fullTag,
      preRelease: preRelease,
      url: json["html_url"] as String,
      publishedAt: publishedAt,
      flavor: flavor,
      apkUrl: apkUrl,
      apkMirrors: apkMirrors,
      apkSha256: apkSha256,
      mandatory: json["mandatory"] == true,
    );
  }
}
