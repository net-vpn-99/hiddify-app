import 'dart:convert';
import 'package:hiddify/features/proxy/model/transport_group.dart';

const _policyPrefix = 'gsl-recommendation-v1:';

/// Absent is legacy; present but invalid is explicit none. No credentials are retained.
class SubscriptionRecommendation {
  const SubscriptionRecommendation._({
    this.known = false,
    this.selected = false,
    this.logicalId = '',
    this.host = '',
    this.port = 0,
    this.selectedTag = '',
  });
  const SubscriptionRecommendation.none() : this._(known: true);
  final bool known, selected;
  final String logicalId, host, selectedTag;
  final int port;

  static SubscriptionRecommendation _decode(Object? value) {
    if (value is! Map ||
        value['schema'] is! int ||
        value['schema'] != 1 ||
        value['status'] != 'selected' ||
        !value.containsKey('logical_id')) {
      return const SubscriptionRecommendation.none();
    }
    final id = value['logical_id'];
    final endpoint = value['endpoint'];
    if ((id != null && (id is! String || !RegExp(r'^[A-Za-z0-9_-]{1,64}$').hasMatch(id))) ||
        endpoint is! Map ||
        endpoint['host'] is! String ||
        endpoint['port'] is! int) {
      return const SubscriptionRecommendation.none();
    }
    final host = endpoint['host'] as String;
    final port = endpoint['port'] as int;
    if (host.isEmpty || host.length > 253 || RegExp(r'[\x00-\x20\x7f]').hasMatch(host) || port < 1 || port > 65535) {
      return const SubscriptionRecommendation.none();
    }
    return SubscriptionRecommendation._(
      known: true,
      selected: true,
      logicalId: id as String? ?? '',
      host: host.toLowerCase(),
      port: port,
    );
  }

  static SubscriptionRecommendation read(String raw) {
    try {
      final value = jsonDecode(raw);
      if (value is! Map) return const SubscriptionRecommendation._();
      final metadata = value['gsl_transports'];
      if (metadata is Map && metadata.containsKey('recommendation')) {
        return value['schema'] == 1 && metadata['schema'] == 1
            ? _decode(metadata['recommendation'])
            : const SubscriptionRecommendation.none();
      }
      final outbounds = value['outbounds'];
      if (outbounds is! List) return const SubscriptionRecommendation._();
      final markers = outbounds
          .whereType<Map>()
          .where((o) => o['type'] == 'block' && o['tag'] is String && (o['tag'] as String).startsWith(_policyPrefix))
          .toList();
      if (markers.isEmpty) return const SubscriptionRecommendation._();
      if (markers.length != 1) return const SubscriptionRecommendation.none();
      final tag = markers.single['tag'] as String;
      if (!tag.endsWith('§hide§') || tag.length > 8192) return const SubscriptionRecommendation.none();
      final payload = tag.substring(_policyPrefix.length, tag.length - '§hide§'.length);
      return _decode(jsonDecode(utf8.decode(base64Url.decode(base64Url.normalize(payload)))))._bind(outbounds);
    } catch (_) {
      // An invalid metadata carrier is never silently downgraded to legacy.
      return raw.contains(_policyPrefix) || raw.contains('"recommendation"')
          ? const SubscriptionRecommendation.none()
          : const SubscriptionRecommendation._();
    }
  }

  SubscriptionRecommendation _bind(List<dynamic> outbounds) {
    if (!selected) return this;
    final matches = <String>[];
    for (final outbound in outbounds.whereType<Map>()) {
      final tag = outbound['tag'];
      if (tag is! String) continue;
      final group = GslTransportGroup.tryParse(tag);
      if (logicalId.isNotEmpty) {
        if (group?.id != logicalId) continue;
        final endpoints = group!.endpoints.where(
          (e) =>
              e['host'] is String &&
              (e['host'] as String).toLowerCase() == host &&
              e['port'] == port &&
              e['available'] == true,
        );
        if (endpoints.length == 1) matches.add(tag);
      } else if (group == null &&
          !tag.startsWith(gslEndpointPrefix) &&
          !const {'selector', 'urltest', 'direct', 'block', 'dns', 'dns-out'}.contains(outbound['type']) &&
          (outbound['server'] as String?)?.toLowerCase() == host &&
          outbound['server_port'] == port) {
        matches.add(tag);
      }
    }
    if (matches.length != 1) return const SubscriptionRecommendation.none();
    return SubscriptionRecommendation._(
      known: true,
      selected: true,
      logicalId: logicalId,
      host: host,
      port: port,
      selectedTag: matches.single,
    );
  }

  String? defaultTag(List<String> tags) {
    if (!known) return tags.firstOrNull;
    if (!selected || selectedTag.isEmpty) return null;
    final matches = tags
        .where((tag) => logicalId.isNotEmpty ? GslTransportGroup.tryParse(tag)?.id == logicalId : tag == selectedTag)
        .toList();
    return matches.length == 1 ? matches.single : null;
  }

  Map<String, dynamic> _json() => selected
      ? {
          'schema': 1,
          'status': 'selected',
          'logical_id': logicalId.isEmpty ? null : logicalId,
          'endpoint': {'host': host, 'port': port},
        }
      : {'schema': 1, 'status': 'none', 'logical_id': null, 'endpoint': null};
}

/// Preserve the decision around the existing native conversion without modifying its routing.
/// The existing builder explicitly excludes block outbounds from proxy selection.
String withConvertedRecommendation(String original, String converted) {
  var policy = SubscriptionRecommendation.read(original);
  final document = jsonDecode(converted);
  if (document is! Map<String, dynamic> || document['outbounds'] is! List) {
    if (policy.known) throw const FormatException('Converted recommendation requires real outbounds');
    return converted;
  }
  final outbounds = (document['outbounds'] as List)
      .where((o) => !(o is Map && o['tag'] is String && (o['tag'] as String).startsWith(_policyPrefix)))
      .toList();
  if (policy.known) {
    policy = policy._bind(outbounds);
    final payload = base64Url.encode(utf8.encode(jsonEncode(policy._json()))).replaceAll('=', '');
    outbounds.add({'type': 'block', 'tag': '$_policyPrefix$payload§hide§'});
  } else if (outbounds.length == (document['outbounds'] as List).length) {
    return converted;
  }
  document['outbounds'] = outbounds;
  return jsonEncode(document);
}
