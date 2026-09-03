import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_hooks/flutter_hooks.dart';
import 'package:gap/gap.dart';
import 'package:go_router/go_router.dart';
import 'package:hiddify/core/localization/translations.dart';
import 'package:hiddify/features/app_update/data/apk_installer.dart';
import 'package:hiddify/features/app_update/model/remote_version_entity.dart';
import 'package:hiddify/features/app_update/notifier/app_update_notifier.dart';
import 'package:hiddify/utils/utils.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

class NewVersionDialog extends HookConsumerWidget with PresLogger {
  NewVersionDialog(this.currentVersion, this.newVersion, {super.key, this.canIgnore = true});

  final String currentVersion;
  final RemoteVersionEntity newVersion;
  final bool canIgnore;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = ref.watch(translationsProvider).requireValue;
    final theme = Theme.of(context);

    final downloading = useState(false);
    final progress = useState<double>(0);
    final error = useState<String?>(null);
    final cancelToken = useMemoized(() => CancelToken());

    // 安卓 + 有直链 → 应用内下载安装；否则退回打开下载页
    final canInApp = !kIsWeb && Platform.isAndroid && (newVersion.apkUrl?.isNotEmpty ?? false);

    Future<void> startInAppUpdate() async {
      error.value = null;
      progress.value = 0;
      downloading.value = true;
      try {
        await ApkInstaller.downloadAndInstall(
          newVersion.apkUrl!,
          sha256Hex: newVersion.apkSha256,
          cancelToken: cancelToken,
          onProgress: (p) => progress.value = p,
        );
        if (context.mounted) context.pop(); // 安装器已拉起
      } catch (e) {
        if (e is DioException && CancelToken.isCancel(e)) return;
        error.value = '下载失败，可改用官网下载';
        downloading.value = false;
      }
    }

    if (downloading.value) {
      return AlertDialog(
        title: Text(t.dialogs.newVersion.title),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('正在下载更新…'),
            const Gap(12),
            LinearProgressIndicator(value: progress.value >= 0 ? progress.value : null),
            const Gap(6),
            Text(
              progress.value >= 0 ? '${(progress.value * 100).toStringAsFixed(0)}%' : '',
              style: theme.textTheme.bodySmall,
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () {
              cancelToken.cancel();
              downloading.value = false;
            },
            child: Text(t.common.cancel),
          ),
        ],
      );
    }

    return PopScope(
      canPop: canIgnore,
      child: AlertDialog(
        title: Text(t.dialogs.newVersion.title),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(t.dialogs.newVersion.msg),
            const Gap(8),
            Text.rich(
              TextSpan(
                children: [
                  TextSpan(text: t.dialogs.newVersion.currentVersion, style: theme.textTheme.bodySmall),
                  TextSpan(text: currentVersion, style: theme.textTheme.labelMedium),
                ],
              ),
            ),
            Text.rich(
              TextSpan(
                children: [
                  TextSpan(text: t.dialogs.newVersion.newVersion, style: theme.textTheme.bodySmall),
                  TextSpan(text: newVersion.presentVersion, style: theme.textTheme.labelMedium),
                ],
              ),
            ),
            if (!canIgnore) ...[
              const Gap(8),
              Text('此版本为必须更新，请立即升级后继续使用。',
                  style: TextStyle(color: theme.colorScheme.error, fontSize: 12)),
            ],
            if (error.value != null) ...[
              const Gap(8),
              Text(error.value!, style: TextStyle(color: theme.colorScheme.error, fontSize: 12)),
            ],
          ],
        ),
        actions: [
          if (canIgnore) ...[
            TextButton(
              onPressed: () async {
                // 以后再说 = 忽略这个版本，下个版本才再提醒
                await ref.read(appUpdateNotifierProvider.notifier).ignoreRelease(newVersion);
                if (context.mounted) context.pop();
              },
              child: const Text('以后再说'),
            ),
          ],
          TextButton(
            onPressed: () async {
              if (canInApp) {
                await startInAppUpdate();
              } else {
                await UriUtils.tryLaunch(Uri.parse(newVersion.url));
              }
            },
            child: Text(t.dialogs.newVersion.updateNow),
          ),
        ],
      ),
    );
  }
}
