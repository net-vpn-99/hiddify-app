import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:hiddify/core/app_info/app_info_provider.dart';
import 'package:hiddify/features/panel_auth/notifier/panel_auth.dart';
import 'package:hiddify/features/support/model/support_message.dart';
import 'package:hiddify/features/support/notifier/support_chat_notifier.dart';
import 'package:hiddify/features/support/widget/support_image_viewer.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

class SupportChatPage extends ConsumerStatefulWidget {
  const SupportChatPage({super.key});

  @override
  ConsumerState<SupportChatPage> createState() => _SupportChatPageState();
}

class _SupportChatPageState extends ConsumerState<SupportChatPage> {
  final _input = TextEditingController();
  final _scroll = ScrollController();
  int _lastCount = 0;

  @override
  void initState() {
    super.initState();
    final notifier = ref.read(supportChatNotifierProvider.notifier);
    notifier.bindIdentity(
      email: ref.read(panelAuthProvider).email,
      version: ref.read(appInfoProvider).valueOrNull?.version,
    );
    // 套餐名单独拉一次（拿不到不影响聊天）。
    ref.read(panelAuthProvider.notifier).fetchAccount().then((acc) {
      if (acc?.planName != null) notifier.bindIdentity(plan: acc!.planName);
    });
    WidgetsBinding.instance.addPostFrameCallback((_) => notifier.openChat());
  }

  @override
  void dispose() {
    ref.read(supportChatNotifierProvider.notifier).dialogClosed();
    _input.dispose();
    _scroll.dispose();
    super.dispose();
  }

  void _maybeAutoScroll(List<SupportMessage> messages) {
    final grew = messages.length > _lastCount;
    final mineLast = messages.isNotEmpty && messages.last.mine;
    _lastCount = messages.length;
    if (!grew && !mineLast) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_scroll.hasClients) return;
      final pos = _scroll.position;
      final nearBottom = pos.maxScrollExtent - pos.pixels < 160;
      if (grew && !mineLast && !nearBottom) return; // 用户在往上翻历史，别打扰
      _scroll.animateTo(pos.maxScrollExtent, duration: const Duration(milliseconds: 200), curve: Curves.easeOut);
    });
  }

  Future<void> _pickFromGallery() async {
    FocusScope.of(context).unfocus();
    try {
      final result = await FilePicker.platform.pickFiles(
        type: FileType.image,
        allowMultiple: true,
      );
      final paths = result?.files.map((f) => f.path).whereType<String>().toList() ?? const [];
      if (paths.isNotEmpty) {
        await ref.read(supportChatNotifierProvider.notifier).sendImages(paths);
      }
    } catch (_) {
      _snack('打开相册失败');
    }
  }

  void _send() {
    final text = _input.text;
    if (text.trim().isEmpty) return;
    _input.clear();
    ref.read(supportChatNotifierProvider.notifier).sendText(text);
  }

  void _snack(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(supportChatNotifierProvider);
    _maybeAutoScroll(state.messages);

    return Scaffold(
      appBar: AppBar(title: const Text('在线客服')),
      body: Column(
        children: [
          if (state.error != null)
            Container(
              width: double.infinity,
              color: Theme.of(context).colorScheme.errorContainer,
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              child: Text(
                state.error!,
                style: TextStyle(color: Theme.of(context).colorScheme.onErrorContainer, fontSize: 12),
              ),
            )
          else if (state.connecting && !state.ready)
            const LinearProgressIndicator(minHeight: 2),
          Expanded(child: _messageList(state)),
          _inputBar(state),
        ],
      ),
    );
  }

  Widget _messageList(SupportChatState state) {
    if (state.messages.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Text(
            state.ready ? '说说遇到的问题，客服看到会尽快回复。' : '正在连接客服…',
            textAlign: TextAlign.center,
            style: TextStyle(color: Theme.of(context).colorScheme.outline),
          ),
        ),
      );
    }
    return ListView.builder(
      controller: _scroll,
      padding: const EdgeInsets.symmetric(vertical: 12),
      itemCount: state.messages.length,
      itemBuilder: (context, i) {
        final m = state.messages[i];
        final prev = i > 0 ? state.messages[i - 1] : null;
        final showTime = m.timeMs > 0 && (prev == null || m.timeMs - prev.timeMs > 5 * 60 * 1000);
        return Column(
          children: [
            if (showTime) _timeLabel(m.timeMs),
            _bubble(m),
          ],
        );
      },
    );
  }

  Widget _timeLabel(int ms) {
    final d = DateTime.fromMillisecondsSinceEpoch(ms);
    final now = DateTime.now();
    final sameDay = d.year == now.year && d.month == now.month && d.day == now.day;
    final hh = d.hour.toString().padLeft(2, '0');
    final mm = d.minute.toString().padLeft(2, '0');
    final text = sameDay ? '$hh:$mm' : '${d.month}月${d.day}日 $hh:$mm';
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Text(text, style: TextStyle(fontSize: 11, color: Theme.of(context).colorScheme.outline)),
    );
  }

  Widget _bubble(SupportMessage m) {
    final theme = Theme.of(context);

    if (m.system) {
      return Padding(
        padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 6),
        child: Text(
          m.text,
          textAlign: TextAlign.center,
          style: TextStyle(fontSize: 11, color: theme.colorScheme.outline),
        ),
      );
    }

    final bg = m.mine ? theme.colorScheme.primary : theme.colorScheme.surfaceContainerHighest;
    final fg = m.mine ? theme.colorScheme.onPrimary : theme.colorScheme.onSurface;

    Widget content;
    if (m.hasImage) {
      final hasRemote = m.imageUrl.isNotEmpty;
      content = GestureDetector(
        onTap: () => SupportImageViewer.show(
          context,
          imageUrl: hasRemote ? m.imageUrl : null,
          localPath: hasRemote ? null : m.localImagePath,
        ),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(12),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 200, maxHeight: 220),
            child: m.imageUrl.isNotEmpty
                ? Image.network(m.imageUrl, fit: BoxFit.cover)
                : Image.file(File(m.localImagePath!), fit: BoxFit.cover),
          ),
        ),
      );
    } else {
      content = Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
        decoration: BoxDecoration(color: bg, borderRadius: BorderRadius.circular(14)),
        child: Text(m.text, style: TextStyle(color: fg, fontSize: 14)),
      );
    }

    final row = Row(
      mainAxisAlignment: m.mine ? MainAxisAlignment.end : MainAxisAlignment.start,
      children: [
        if (m.mine && m.failed)
          IconButton(
            visualDensity: VisualDensity.compact,
            icon: Icon(Icons.error_outline, color: theme.colorScheme.error, size: 20),
            onPressed: () => ref.read(supportChatNotifierProvider.notifier).retry(m),
            tooltip: '重试',
          ),
        if (m.mine && m.pending)
          const Padding(
            padding: EdgeInsets.only(right: 6),
            child: SizedBox(width: 12, height: 12, child: CircularProgressIndicator(strokeWidth: 1.5)),
          ),
        ConstrainedBox(
          constraints: BoxConstraints(maxWidth: MediaQuery.of(context).size.width * 0.74),
          child: content,
        ),
      ],
    );

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
      child: GestureDetector(
        onLongPress: m.text.isEmpty
            ? null
            : () {
                Clipboard.setData(ClipboardData(text: m.text));
                _snack('已复制');
              },
        child: row,
      ),
    );
  }

  Widget _inputBar(SupportChatState state) {
    return SafeArea(
      top: false,
      child: Container(
        padding: const EdgeInsets.fromLTRB(8, 6, 8, 6),
        decoration: BoxDecoration(
          border: Border(top: BorderSide(color: Theme.of(context).dividerColor)),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            IconButton(
              icon: const Icon(Icons.image_outlined),
              onPressed: state.ready ? _pickFromGallery : null,
              tooltip: '发图片',
            ),
            Expanded(
              child: TextField(
                controller: _input,
                minLines: 1,
                maxLines: 4,
                decoration: const InputDecoration(
                  hintText: '输入消息…',
                  isDense: true,
                  border: OutlineInputBorder(),
                  contentPadding: EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                ),
              ),
            ),
            const SizedBox(width: 4),
            ValueListenableBuilder<TextEditingValue>(
              valueListenable: _input,
              builder: (_, value, _) {
                final can = value.text.trim().isNotEmpty && state.ready;
                return IconButton.filled(
                  onPressed: can ? _send : null,
                  icon: const Icon(Icons.send_rounded),
                );
              },
            ),
          ],
        ),
      ),
    );
  }
}
