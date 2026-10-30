import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/l10n/strings_zh.dart';
import '../../room/room_code.dart';

/// 房间号输入卡片：和"显示房间号"同一张卡片的观感，点进去就能改。
///
/// 刻意不用带下划线/边框的普通输入框；校验错误直接显示在卡片里，
/// 不弹对话框（弹窗会把刚输的字挡住）。
final class RoomCodeCard extends StatelessWidget {
  const RoomCodeCard({
    required this.controller,
    this.onChanged,
    this.onCopy,
    super.key,
  });

  final TextEditingController controller;
  final ValueChanged<String>? onChanged;
  final ValueChanged<String>? onCopy;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return ValueListenableBuilder<TextEditingValue>(
      valueListenable: controller,
      builder: (context, value, _) {
        final text = value.text.trim();
        final invalid = text.isNotEmpty && !RoomCode.isValid(text);
        return Card(
          clipBehavior: Clip.antiAlias,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 8, 12),
            child: Column(
              children: [
                Text(Zh.roomNumber, style: theme.textTheme.titleSmall),
                Row(
                  children: [
                    Expanded(
                      child: TextField(
                        controller: controller,
                        textAlign: TextAlign.center,
                        textCapitalization: TextCapitalization.characters,
                        inputFormatters: [
                          LengthLimitingTextInputFormatter(RoomCode.maxLength),
                        ],
                        style: theme.textTheme.headlineMedium?.copyWith(
                          fontWeight: FontWeight.bold,
                          letterSpacing: 2,
                        ),
                        decoration: InputDecoration.collapsed(
                          hintText: Zh.roomNumberHint,
                          hintStyle: theme.textTheme.headlineSmall?.copyWith(
                            color: theme.disabledColor,
                            letterSpacing: 2,
                          ),
                        ),
                        onChanged: onChanged,
                      ),
                    ),
                    if (value.text.isNotEmpty)
                      IconButton(
                        tooltip: Zh.clearRoomCode,
                        icon: const Icon(Icons.backspace_outlined),
                        onPressed: () {
                          controller.clear();
                          onChanged?.call('');
                        },
                      ),
                    IconButton(
                      tooltip: Zh.copyRoomNumber,
                      icon: const Icon(Icons.copy),
                      onPressed: text.isEmpty ? null : () => onCopy?.call(text),
                    ),
                  ],
                ),
                if (invalid)
                  Padding(
                    padding: const EdgeInsets.only(top: 6),
                    child: Text(
                      Zh.roomCodeInvalid,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.error,
                      ),
                    ),
                  ),
              ],
            ),
          ),
        );
      },
    );
  }
}
