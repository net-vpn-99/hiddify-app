import 'dart:io';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:gal/gal.dart';

/// 全屏看图：双指缩放 + 长按/按钮保存到相册。远端图和本地待发图都能看。
class SupportImageViewer extends StatefulWidget {
  const SupportImageViewer({super.key, this.imageUrl, this.localPath})
      : assert(imageUrl != null || localPath != null);

  final String? imageUrl;
  final String? localPath;

  static Future<void> show(BuildContext context, {String? imageUrl, String? localPath}) {
    return Navigator.of(context).push(
      PageRouteBuilder(
        opaque: false,
        barrierColor: Colors.black,
        pageBuilder: (_, _, _) => SupportImageViewer(imageUrl: imageUrl, localPath: localPath),
      ),
    );
  }

  @override
  State<SupportImageViewer> createState() => _SupportImageViewerState();
}

class _SupportImageViewerState extends State<SupportImageViewer> {
  bool _saving = false;

  Future<void> _save() async {
    if (_saving) return;
    setState(() => _saving = true);
    try {
      if (!await Gal.hasAccess(toAlbum: true)) {
        final granted = await Gal.requestAccess(toAlbum: true);
        if (!granted) {
          _toast('没有相册权限，去系统设置里打开');
          return;
        }
      }
      if (widget.localPath != null) {
        await Gal.putImage(widget.localPath!, album: '光速');
      } else {
        final res = await Dio().get<List<int>>(
          widget.imageUrl!,
          options: Options(responseType: ResponseType.bytes),
        );
        await Gal.putImageBytes(Uint8List.fromList(res.data ?? const []), album: '光速');
      }
      _toast('已保存到相册');
    } on GalException catch (e) {
      _toast(e.type == GalExceptionType.accessDenied ? '没有相册权限，去系统设置里打开' : '保存失败');
    } catch (_) {
      _toast('保存失败');
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  void _toast(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
  }

  @override
  Widget build(BuildContext context) {
    final Widget image = widget.localPath != null
        ? Image.file(File(widget.localPath!))
        : Image.network(widget.imageUrl!);

    return Scaffold(
      backgroundColor: Colors.transparent,
      appBar: AppBar(
        backgroundColor: Colors.black,
        foregroundColor: Colors.white,
        actions: [
          IconButton(
            onPressed: _saving ? null : _save,
            icon: _saving
                ? const SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
                  )
                : const Icon(Icons.download_rounded),
            tooltip: '保存到相册',
          ),
        ],
      ),
      body: GestureDetector(
        onTap: () => Navigator.of(context).maybePop(),
        onLongPress: _saving ? null : _save,
        child: Center(
          child: InteractiveViewer(
            maxScale: 5,
            child: image,
          ),
        ),
      ),
    );
  }
}
