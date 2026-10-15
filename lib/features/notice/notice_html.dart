import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';

/// 公告正文的一块（10-15 公告改版，跟 Windows AccountController::NoticeBlocks 同一套规则）：
/// p 段落 / li 条目 / h 整行加粗的小标题 / quote 重点横幅（<blockquote>）/ button 单独占一行的链接（只取第一个）。
class NoticeBlock {
  const NoticeBlock(this.kind, this.html, [this.href = '']);
  final String kind;
  final String html;
  final String href;
}

/// 公告正文只留 p / br / b / strong / a / ul / li。图片和脚本整段丢掉。
class NoticeHtml {
  static const _quoteMark = '\uE000';

  /// 一行一块；写在句子中间的链接留在句子里，不再另做按钮（以前同一个链接出现两次）。
  static List<NoticeBlock> blocks(String html) {
    var s = _dropDangerous(html);
    s = s.replaceAll(RegExp(r'<blockquote\b[^>]*>', caseSensitive: false), '<br>$_quoteMark');
    s = s.replaceAll(RegExp('</blockquote>|</p>|</div>|</h[1-6]>|</li>', caseSensitive: false), '<br>');
    s = s.replaceAll(RegExp(r'<li\b[^>]*>', caseSensitive: false), '• ');
    s = s.replaceAll(RegExp(r'<br\s*/?>', caseSensitive: false), '\n');
    // 只留 b / strong / a，别的标签去掉（p、ul、span…）
    s = s.replaceAllMapped(RegExp(r'</?([a-zA-Z0-9]+)(\s[^>]*)?>'), (m) {
      final name = m.group(1)!.toLowerCase();
      return name == 'b' || name == 'strong' || name == 'a' ? m.group(0)! : '';
    });
    final heading = RegExp(r'^<(b|strong)>([\s\S]*)</\1>$', caseSensitive: false);
    final onlyLink = RegExp(r'''^<a\b[^>]*href\s*=\s*['"]([^'"]*)['"][^>]*>([\s\S]*)</a>$''', caseSensitive: false);
    final anyTag = RegExp('<[^>]+>');
    final out = <NoticeBlock>[];
    var haveButton = false;
    for (var line in s.split('\n')) {
      line = line.trim();
      var kind = 'p';
      if (line.startsWith(_quoteMark)) {
        kind = 'quote';
        line = line.substring(1).trim();
      } else if (line.startsWith('• ')) {
        kind = 'li';
        line = line.substring(2).trim();
      }
      if (line.isEmpty) continue;
      final h = heading.firstMatch(line);
      final link = onlyLink.firstMatch(line);
      if (kind == 'p' && h != null && !anyTag.hasMatch(h.group(2)!)) {
        out.add(NoticeBlock('h', h.group(2)!.trim()));
      } else if (kind == 'p' && link != null && !haveButton && _http(link.group(1)!)) {
        haveButton = true;
        out.add(NoticeBlock('button', _decode(link.group(2)!.replaceAll(anyTag, '')).trim(), link.group(1)!));
      } else {
        out.add(NoticeBlock(kind, line));
      }
    }
    return out;
  }

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
          final url = href;
          final recognizer = TapGestureRecognizer()..onTap = () => onLink(url);
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
