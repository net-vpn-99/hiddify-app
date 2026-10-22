import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:hiddify/features/diagnostic/diag_service.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

/// 导出诊断：收集日志 + 设置上传，弹出诊断码给客服。以前是「帮助与诊断」里的「连接诊断」，
/// 10-22 并进连接检查，入口在检查结果页底部（docs/计划/连接检查.md 第八节）。
Future<void> exportDiagnostics(BuildContext context, WidgetRef ref) async {
  final result = await uploadDiagnostics(ref);
  if (!context.mounted) return;
  if (result.code != null) {
    await showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('已上传给客服'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('把下面这个诊断码发给客服：'),
            const SizedBox(height: 12),
            SelectableText(
              result.code!,
              style: const TextStyle(fontSize: 22, fontWeight: FontWeight.bold, letterSpacing: 1),
            ),
          ],
        ),
        actions: [
          FilledButton(
            onPressed: () {
              Clipboard.setData(ClipboardData(text: result.code!));
              Navigator.of(ctx).pop();
            },
            child: const Text('复制诊断码'),
          ),
        ],
      ),
    );
  } else {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(result.error ?? '上传失败')));
  }
}
