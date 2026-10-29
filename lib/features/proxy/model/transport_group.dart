import 'dart:convert';
import 'package:hooks_riverpod/hooks_riverpod.dart';

const gslGroupPrefix = 'gsl-ln-v1:';
const gslEndpointPrefix = 'gsl-ep-v1:';

class GslTransportGroup {
  GslTransportGroup(this.id, this.name, this.revision, this.endpoints);
  final String id;
  final String name;
  final int revision;
  final List<Map<String, dynamic>> endpoints;

  bool get available => endpoints.any((endpoint) => endpoint['available'] == true);

  String get country =>
      const {'日本': 'JP', '香港': 'HK', '美国': 'US', '新加坡': 'SG', '韩国': 'KR', '台湾': 'TW', '英国': 'GB'}[name
          .trim()
          .split(' ')
          .first] ??
      '';

  static GslTransportGroup? tryParse(String tag) {
    // Some core status displays add the selected inner tag after an arrow.
    final raw = tag.split('→').first.trim();
    if (!raw.startsWith(gslGroupPrefix) || raw.length > 8192) return null;
    try {
      final value = jsonDecode(
        utf8.decode(base64Url.decode(base64Url.normalize(raw.substring(gslGroupPrefix.length)))),
      );
      if (value is! Map<String, dynamic> ||
          value['id'] is! String ||
          value['name'] is! String ||
          value['revision'] is! int ||
          (value['revision'] as int) <= 0 ||
          value['endpoints'] is! List)
        return null;
      final id = value['id'] as String;
      final name = value['name'] as String;
      final ids = <String>{};
      final kinds = <String>{};
      final endpoints = <Map<String, dynamic>>[];
      if (!RegExp(r'^[A-Za-z][A-Za-z0-9_.-]{0,95}$').hasMatch(id) ||
          name.isEmpty ||
          name.length > 512 ||
          (value['endpoints'] as List).length != 2)
        return null;
      for (final item in value['endpoints'] as List) {
        if (item is! Map<String, dynamic> ||
            item['id'] is! String ||
            item['kind'] is! String ||
            item['available'] is! bool ||
            item['tag'] is! String ||
            !ids.add(item['id'] as String) ||
            !kinds.add(item['kind'] as String) ||
            !const ['tcp', 'udp'].contains(item['kind']))
          return null;
        if (!(item['tag'] as String).startsWith('$gslEndpointPrefix${item['id']}:') ||
            !(item['tag'] as String).endsWith('§hide§'))
          return null;
        endpoints.add(item);
      }
      return GslTransportGroup(id, name, value['revision'] as int, endpoints);
    } catch (_) {
      return null;
    }
  }
}

bool isLogicalTransportTag(String tag) => GslTransportGroup.tryParse(tag) != null;
bool isPhysicalTransportTag(String tag) => tag.startsWith(gslEndpointPrefix);

class TransportSelectionState {
  const TransportSelectionState({
    this.group = '',
    this.operation = '',
    this.phase = 'idle',
    this.endpoint = '',
    this.reason = '',
  });
  final String group, operation, phase, endpoint, reason;
  bool get pending => phase == 'awaiting_selection' || phase == 'checking';
  bool get selected => phase == 'selected';
}

final transportSelectionProvider = StateProvider<TransportSelectionState>((ref) => const TransportSelectionState());

/// Explicit subscription availability, independent of display names or account status labels.
Set<String> unavailableTransportGroups(String raw) {
  try {
    final config = jsonDecode(raw);
    if (config is! Map || config['outbounds'] is! List) return {};
    final groups = <GslTransportGroup>[];
    for (final outbound in config['outbounds'] as List) {
      if (outbound is! Map || outbound['tag'] is! String) continue;
      final group = GslTransportGroup.tryParse(outbound['tag'] as String);
      if (group != null) groups.add(group);
    }
    return {for (final group in groups) if (!group.available) group.id};
  } catch (_) {
    return {};
  }
}
