import 'package:flutter/foundation.dart';

/// 一条客服会话消息。远端消息 [id] 用 Chatwoot 的真实 id；本地「发送中 / 发送失败」
/// 的消息用递减的负数当临时 id，发送成功后被远端消息替换。
@immutable
class SupportMessage {
  const SupportMessage({
    required this.id,
    this.text = '',
    this.imageUrl = '',
    this.localImagePath,
    this.mine = false,
    this.system = false,
    this.timeMs = 0,
    this.pending = false,
    this.failed = false,
  });

  final int id;

  /// 文字内容（图片消息可为空）。
  final String text;

  /// 远端图片地址（收到的图 / 已发成功的图）。
  final String imageUrl;

  /// 本地待发 / 发送中 / 失败的图片文件路径，用于气泡预览和「重发」。
  final String? localImagePath;

  /// true = 自己发的（靠右）；false = 客服发的（靠左）。
  final bool mine;

  /// true = 系统提示（居中小字，例如「会话已创建」）。
  final bool system;

  /// 毫秒时间戳；0 = 未知。
  final int timeMs;

  /// 正在发送。
  final bool pending;

  /// 发送失败，可点「重发」。
  final bool failed;

  bool get hasImage => imageUrl.isNotEmpty || (localImagePath != null && localImagePath!.isNotEmpty);

  SupportMessage copyWith({
    int? id,
    String? text,
    String? imageUrl,
    String? localImagePath,
    bool? mine,
    bool? system,
    int? timeMs,
    bool? pending,
    bool? failed,
  }) {
    return SupportMessage(
      id: id ?? this.id,
      text: text ?? this.text,
      imageUrl: imageUrl ?? this.imageUrl,
      localImagePath: localImagePath ?? this.localImagePath,
      mine: mine ?? this.mine,
      system: system ?? this.system,
      timeMs: timeMs ?? this.timeMs,
      pending: pending ?? this.pending,
      failed: failed ?? this.failed,
    );
  }

  @override
  bool operator ==(Object other) =>
      other is SupportMessage &&
      other.id == id &&
      other.text == text &&
      other.imageUrl == imageUrl &&
      other.localImagePath == localImagePath &&
      other.mine == mine &&
      other.system == system &&
      other.timeMs == timeMs &&
      other.pending == pending &&
      other.failed == failed;

  @override
  int get hashCode => Object.hash(id, text, imageUrl, localImagePath, mine, system, timeMs, pending, failed);
}
