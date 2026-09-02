import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:hiddify/features/diagnostic/diag_service.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

/// 设置页里的「上传诊断给客服」。收集日志+设置，上传后弹出诊断码。
class DiagTile extends ConsumerStatefulWidget {
  const DiagTile({super.key});

  @override
  ConsumerState<DiagTile> createState() => _DiagTileState();
}

class _DiagTileState extends ConsumerState<DiagTile> {
  bool _busy = false;

  Future<void> _run() async {
    if (_busy) return;
    setState(() => _busy = true);
    final result = await uploadDiagnostics(ref);
    if (!mounted) return;
    setState(() => _busy = false);

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
            TextButton(
              onPressed: () {
                Clipboard.setData(ClipboardData(text: result.code!));
                Navigator.of(ctx).pop();
              },
              child: const Text('复制并关闭'),
            ),
          ],
        ),
      );
    } else {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(result.error ?? '上传失败')),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return Material(
      child: ListTile(
        leading: const Icon(Icons.bug_report_outlined),
        title: const Text('上传诊断给客服'),
        subtitle: const Text('连接有问题时，一键把日志发给客服排查'),
        trailing: _busy
            ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2))
            : const Icon(Icons.chevron_right),
        onTap: _busy ? null : _run,
      ),
    );
  }
}
