import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';

String? _solveAltchaJob(Map<String, Object> job) {
  final salt = job['salt']! as String;
  final challenge = job['challenge']! as String;
  final signature = job['signature']! as String;
  final maxnumber = job['maxnumber']! as int;
  final started = DateTime.now();
  for (var n = 0; n <= maxnumber; n++) {
    if (DateTime.now().difference(started).inSeconds >= 60) return null;
    final dig = sha256.convert(utf8.encode(salt + n.toString())).toString();
    if (dig == job['challenge']) {
      return base64.encode(utf8.encode(jsonEncode({
        'algorithm': 'SHA-256',
        'challenge': challenge,
        'number': n,
        'salt': salt,
        'signature': signature,
      })));
    }
  }
  return null;
}

/// 要一道题并在后台 isolate 算出答案。失败或超过 60 秒返回 null。
Future<String?> solveAltcha(Dio dio) async {
  try {
    final res = await dio.get<dynamic>(
      '/api/v1/guest/gsl_altcha/challenge',
      options: Options(receiveTimeout: const Duration(seconds: 3)),
    );
    final raw = res.data;
    final data = raw is Map ? raw['data'] : null;
    if (data is! Map) return null;
    final salt = data['salt'];
    final challenge = data['challenge'];
    final signature = data['signature'];
    final maxnumber = data['maxnumber'];
    if (salt is! String || challenge is! String || signature is! String) return null;
    final max = maxnumber is int ? maxnumber : int.tryParse('$maxnumber') ?? -1;
    if (max < 0) return null;
    return await compute(
      _solveAltchaJob,
      {'salt': salt, 'challenge': challenge, 'signature': signature, 'maxnumber': max},
    ).timeout(const Duration(seconds: 60));
  } catch (_) {
    return null;
  }
}
