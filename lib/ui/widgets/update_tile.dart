import 'package:flutter/material.dart';

import '../../core/l10n/strings_zh.dart';
import '../update/update_controller.dart';

/// 设置页的「检查更新」：当前版本 + 状态 + 下载/取消/安装/兜底链接。
///
/// 只有用户点按钮才动作；安装一律走系统安装器（用户确认），不做静默安装。
final class UpdateTile extends StatefulWidget {
  const UpdateTile({this.controller, super.key});

  /// 可注入（单测/预览用）；为空时自己建一个。
  final UpdateController? controller;

  @override
  State<UpdateTile> createState() => _UpdateTileState();
}

final class _UpdateTileState extends State<UpdateTile> {
  late final UpdateController _controller =
      widget.controller ?? UpdateController();
  late final bool _owns = widget.controller == null;

  @override
  void initState() {
    super.initState();
    _controller.loadCurrentVersion();
  }

  @override
  void dispose() {
    if (_owns) _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return AnimatedBuilder(
      animation: _controller,
      builder: (context, _) {
        final controller = _controller;
        final status = _statusLine(controller);
        return Card(
          elevation: 0,
          color: theme.colorScheme.surfaceContainerHighest,
          child: Column(
            children: [
              ListTile(
                leading: const Icon(Icons.system_update_alt),
                title: const Text(Zh.updateTitle),
                subtitle: Text(
                  '当前版本 ${controller.currentVersion.isEmpty ? Zh.versionUnavailable : controller.currentVersion}'
                  '${status.isEmpty ? '' : '\n$status'}',
                ),
                isThreeLine: status.isNotEmpty,
                trailing: TextButton(
                  onPressed: controller.busy ? null : controller.check,
                  child: Text(
                    controller.phase == UpdatePhase.upToDate
                        ? Zh.updateRecheck
                        : Zh.updateCheck,
                  ),
                ),
              ),
              if (controller.phase == UpdatePhase.downloading)
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                  child: Column(
                    children: [
                      LinearProgressIndicator(value: controller.progress),
                      const SizedBox(height: 8),
                      Row(
                        children: [
                          Expanded(
                            child: Text(
                              '${_mb(controller.receivedBytes)}'
                              '${controller.totalBytes > 0 ? ' / ${_mb(controller.totalBytes)}' : ''}',
                              style: theme.textTheme.bodySmall,
                            ),
                          ),
                          TextButton(
                            onPressed: controller.cancel,
                            child: const Text(Zh.updateCancel),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              if (controller.phase == UpdatePhase.available &&
                  controller.asset != null)
                Align(
                  alignment: Alignment.centerRight,
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                    child: FilledButton(
                      onPressed: controller.download,
                      child: const Text(Zh.updateDownload),
                    ),
                  ),
                ),
              if (controller.phase == UpdatePhase.ready &&
                  controller.filePath != null)
                Align(
                  alignment: Alignment.centerRight,
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                    child: FilledButton(
                      onPressed: controller.install,
                      child: const Text(Zh.updateInstall),
                    ),
                  ),
                ),
              if (controller.phase == UpdatePhase.failed ||
                  (controller.phase == UpdatePhase.available &&
                      controller.asset == null))
                Align(
                  alignment: Alignment.centerRight,
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                    child: TextButton(
                      onPressed: controller.openReleasePage,
                      child: const Text(Zh.updateOpenRelease),
                    ),
                  ),
                ),
            ],
          ),
        );
      },
    );
  }

  String _statusLine(UpdateController controller) {
    switch (controller.phase) {
      case UpdatePhase.idle:
        return '';
      case UpdatePhase.checking:
      case UpdatePhase.upToDate:
      case UpdatePhase.available:
      case UpdatePhase.downloading:
      case UpdatePhase.ready:
      case UpdatePhase.installing:
      case UpdatePhase.failed:
        return controller.message;
    }
  }

  String _mb(int bytes) {
    if (bytes < 1024) return '$bytes B';
    final mb = bytes / (1024 * 1024);
    return mb >= 1
        ? '${mb.toStringAsFixed(1)} MB'
        : '${(bytes / 1024).round()} KB';
  }
}
