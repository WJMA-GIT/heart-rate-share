import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/l10n/strings_zh.dart';

/// 连接失败弹窗：一句中文原因 + 可复制的诊断信息。
///
/// 诊断信息包含：端点、解析到的地址（IPv4/IPv6）、逐地址尝试结果、最终归类。
/// 上一轮现场把 `Failed host lookup` 当成断连原因追偏了，所以这里把原始细节
/// 藏进"可复制"的区域，而不是丢给用户看。
Future<void> showConnectFailure(
  BuildContext context, {
  required String message,
  String? diagnostics,
}) {
  return showDialog<void>(
    context: context,
    builder: (dialogContext) => AlertDialog(
      title: const Text(Zh.connectFailedTitle),
      content: SizedBox(
        width: 420,
        child: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(message),
              if (diagnostics != null && diagnostics.trim().isNotEmpty) ...[
                const SizedBox(height: 16),
                Text(
                  Zh.connectDiagnostics,
                  style: Theme.of(dialogContext).textTheme.titleSmall,
                ),
                const SizedBox(height: 4),
                SelectableText(
                  diagnostics,
                  style: Theme.of(dialogContext).textTheme.bodySmall,
                ),
              ],
            ],
          ),
        ),
      ),
      actions: [
        if (diagnostics != null && diagnostics.trim().isNotEmpty)
          TextButton(
            onPressed: () async {
              await Clipboard.setData(ClipboardData(text: diagnostics));
              if (dialogContext.mounted) {
                ScaffoldMessenger.of(dialogContext).showSnackBar(
                  const SnackBar(content: Text(Zh.connectDiagnosticsCopied)),
                );
              }
            },
            child: const Text(Zh.copyDiagnostics),
          ),
        TextButton(
          onPressed: () => Navigator.of(dialogContext).pop(),
          child: const Text(Zh.close),
        ),
      ],
    ),
  );
}
