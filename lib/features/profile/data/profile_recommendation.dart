import 'dart:io';
import 'package:hiddify/features/proxy/model/subscription_recommendation.dart';

/// Called after the existing core has validated/converted this exact downloaded response.
Future<void> persistProfileRecommendation(String original, String path) async {
  final target = File(path);
  final converted = await target.readAsString();
  final updated = withConvertedRecommendation(original, converted);
  if (updated == converted) return;
  final staging = File('$path.recommendation-${DateTime.now().microsecondsSinceEpoch}.tmp');
  try {
    await staging.writeAsString(updated, flush: true);
    if (await target.readAsString() != converted) {
      throw StateError('Profile changed while binding recommendation');
    }
    await staging.rename(path);
  } finally {
    if (await staging.exists()) await staging.delete();
  }
}

/// Convert and bind in a private staging file; failures leave the old complete profile intact.
Future<T> convertProfileWithRecommendation<T>(
  String inputPath,
  String outputPath,
  Future<T> Function(String stagingPath) convert,
) async {
  final original = await File(inputPath).readAsString();
  final staging = File('$outputPath.validated-${DateTime.now().microsecondsSinceEpoch}.tmp');
  try {
    final result = await convert(staging.path);
    await persistProfileRecommendation(original, staging.path);
    await staging.rename(outputPath);
    return result;
  } finally {
    if (await staging.exists()) await staging.delete();
  }
}
