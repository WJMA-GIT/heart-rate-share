import 'package:flutter/material.dart';

import '../../core/l10n/strings_zh.dart';

/// 自己的房间号展示卡：**只读**。
///
/// 房间号一律由系统生成（创建房间时生成，加入后由服务端确认），用户不能在这里
/// 编辑。左边是"复制自己的"，右边是"粘贴对方的"——两个动作分开，避免把自己的
/// 房间号当成别人的加入目标。
final class RoomCodeCard extends StatelessWidget {
  const RoomCodeCard({
    required this.roomCode,
    this.onCopy,
    this.onPaste,
    super.key,
  });

  /// 自己当前生效的房间号；null = 还没进房间。
  final String? roomCode;

  final ValueChanged<String>? onCopy;

  /// 粘贴对方的房间号（粘贴后进入确认加入，由调用方负责读剪贴板与校验）。
  final VoidCallback? onPaste;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final code = roomCode;
    final copy = onCopy;
    final paste = onPaste;
    return Card(
      clipBehavior: Clip.antiAlias,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(8, 12, 8, 12),
        child: Column(
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Text(Zh.roomNumber, style: theme.textTheme.titleSmall),
                if (code != null) ...[
                  const SizedBox(width: 6),
                  Text(
                    Zh.roomNumberGenerated,
                    style: theme.textTheme.bodySmall,
                  ),
                ],
              ],
            ),
            const SizedBox(height: 4),
            Row(
              children: [
                IconButton(
                  tooltip: Zh.copyRoomNumber,
                  icon: const Icon(Icons.copy),
                  onPressed: code == null || copy == null
                      ? null
                      : () => copy(code),
                ),
                Expanded(
                  child: Semantics(
                    label: code == null
                        ? Zh.roomCodeNone
                        : '${Zh.roomNumber} $code',
                    child: code == null
                        ? Padding(
                            padding: const EdgeInsets.symmetric(vertical: 12),
                            child: Text(
                              Zh.roomCodeNone,
                              textAlign: TextAlign.center,
                              style: theme.textTheme.bodySmall,
                            ),
                          )
                        : FittedBox(
                            fit: BoxFit.scaleDown,
                            child: Text(
                              code,
                              style: theme.textTheme.headlineMedium?.copyWith(
                                fontWeight: FontWeight.bold,
                                letterSpacing: 2,
                              ),
                            ),
                          ),
                  ),
                ),
                IconButton(
                  tooltip: Zh.pasteRoomNumber,
                  icon: const Icon(Icons.content_paste),
                  onPressed: paste,
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
