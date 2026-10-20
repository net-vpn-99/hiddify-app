import 'dart:io';

import 'package:path/path.dart' as p;

class LogPathResolver {
  const LogPathResolver(this._workingDir);

  /// 内核日志的真实位置：hiddify-core 4.x 先 chdir 到工作目录，再写相对路径 `data/box.log`
  /// （`v2/config/hiddify_option.go` 的默认 LogFile）。工作目录下那个 `box.log` 没人写，一直是空的 ——
  /// 10-20 查实：10-17 以来 54 份安卓诊断包的内核日志全空，「走错了」清单、REALITY 证据都读不到。
  static String corePath(Directory workingDir) => p.join(workingDir.path, 'data', 'box.log');

  final Directory _workingDir;

  Directory get directory => _workingDir;

  File coreFile() {
    return File(corePath(directory));
  }

  File appFile() {
    return File(p.join(directory.path, "app.log"));
  }
}
