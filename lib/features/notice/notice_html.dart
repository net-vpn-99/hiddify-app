import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';

/// 公告正文只留 p / br / b / strong / a / ul / li。图片和脚本整段丢掉。
class NoticeHtml {
  static String preview(String html) {
    var s = _dropDangerous(html);
    s = s.replaceAll(RegExp('<br\\s*/?>', caseSensitive: false), ' ');
    s = s.replaceAll(RegExp('</p>|</li>|</div>', caseSensitive: false), ' ');
    s = s.replaceAll(RegExp('<[^>]+>'), '');
    s = _decode(s).replaceAll(RegExp(r'\s+'), ' ').trim();
    return s;
  }

  static List<InlineSpan> spans(
    String html,
    TextStyle style,
    Color link, {
    required void Function(TapGestureRecognizer) keep,
    required void Function(String url) onLink,
  }) {
    final source = _dropDangerous(html);
    final spans = <InlineSpan>[];
    var bold = false;
    String? href;
    final tag = RegExp('<[^>]+>|[^<]+');
    for (final match in tag.allMatches(source)) {
      final token = match.group(0)!;
      if (!token.startsWith('<')) {
        final text = _decode(token);
        if (text.isEmpty) continue;
        if (href != null && _http(href)) {
          final recognizer = TapGestureRecognizer()..onTap = () => onLink(href!);
          keep(recognizer);
          spans.add(TextSpan(
            text: text,
            style: style.copyWith(color: link, fontWeight: bold ? FontWeight.w700 : style.fontWeight),
            recognizer: recognizer,
          ));
        } else {
          spans.add(TextSpan(
            text: text,
            style: bold ? style.copyWith(fontWeight: FontWeight.w700) : style,
          ));
        }
        continue;
      }
      final name = RegExp(r'^</?\s*([a-zA-Z0-9]+)').firstMatch(token)?.group(1)?.toLowerCase() ?? '';
      final closing = token.startsWith('</');
      switch (name) {
        case 'b':
        case 'strong':
          bold = !closing;
        case 'a':
          if (closing) {
            href = null;
          } else {
            final raw = RegExp("href\\s*=\\s*['\"]([^'\"]*)['\"]", caseSensitive: false).firstMatch(token)?.group(1);
            href = raw;
          }
        case 'br':
          spans.add(const TextSpan(text: '\n'));
        case 'p':
        case 'div':
          if (closing) _break(spans);
        case 'li':
          if (!closing) {
            _break(spans);
            spans.add(TextSpan(text: '• ', style: style));
          } else {
            _break(spans);
          }
        default:
          break;
      }
    }
    return spans;
  }

  static void _break(List<InlineSpan> spans) {
    if (spans.isEmpty) return;
    final last = spans.last;
    if (last is TextSpan && (last.text ?? '').endsWith('\n')) return;
    spans.add(const TextSpan(text: '\n'));
  }

  static String _dropDangerous(String html) {
    var s = html;
    s = s.replaceAll(RegExp(r'<script\b[^>]*>[\s\S]*?</script>', caseSensitive: false), '');
    s = s.replaceAll(RegExp(r'<style\b[^>]*>[\s\S]*?</style>', caseSensitive: false), '');
    s = s.replaceAll(RegExp(r'<img\b[^>]*>', caseSensitive: false), '');
    return s;
  }

  static bool _http(String url) {
    final lower = url.toLowerCase();
    return lower.startsWith('http://') || lower.startsWith('https://');
  }

  static String _decode(String s) {
    return s
        .replaceAll('&nbsp;', ' ')
        .replaceAll('&amp;', '&')
        .replaceAll('&lt;', '<')
        .replaceAll('&gt;', '>')
        .replaceAll('&quot;', '"');
  }
}

String noticeDate(int unix) {
  if (unix <= 0) return '';
  final dt = DateTime.fromMillisecondsSinceEpoch(unix * 1000);
  final now = DateTime.now();
  String two(int n) => n.toString().padLeft(2, '0');
  if (dt.year == now.year) return '${two(dt.month)}-${two(dt.day)}';
  return '${dt.year}-${two(dt.month)}-${two(dt.day)}';
}
