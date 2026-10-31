import 'dart:ffi';
import 'dart:io' show exit;
import 'dart:io' show Platform;

/// 无边框窗口的拖动：直接调 Win32（`ReleaseCapture()` + `SendMessage(WM_NCLBUTTONDOWN,
/// HTCAPTION)`），不依赖任何窗口管理插件。
///
/// 为什么不用 `window_manager`：那个插件会子类化窗口过程（WndProc），和 runner 里
/// 的分层窗口/置顶样式在同一个用户回调里打架，实测崩溃码 0xC000041D
/// （STATUS_FATAL_USER_CALLBACK_EXCEPTION，出错模块 window_manager_plugin.dll）。
/// 拖动这么点事，十几行 ffi 就够，没必要交出一个 WndProc 给插件。
void startWindowDrag() {
  if (!Platform.isWindows) return;
  try {
    final user32 = DynamicLibrary.open('user32.dll');
    final getForegroundWindow = user32
        .lookupFunction<IntPtr Function(), int Function()>(
          'GetForegroundWindow',
        );
    final releaseCapture = user32
        .lookupFunction<Int32 Function(), int Function()>('ReleaseCapture');
    final sendMessage = user32
        .lookupFunction<
          IntPtr Function(IntPtr, Uint32, IntPtr, IntPtr),
          int Function(int, int, int, int)
        >('SendMessageW');

    final hwnd = getForegroundWindow();
    if (hwnd == 0) return;
    releaseCapture();
    const wmNcLButtonDown = 0x00A1;
    const htCaption = 2;
    sendMessage(hwnd, wmNcLButtonDown, htCaption, 0);
  } catch (_) {
    // 拖动失败不影响其他功能（窗口仍可用快捷键/鼠标移出边缘调整）
  }
}

/// 最小化 / 关闭：无边框窗口没有系统按钮，自己发 Win32 消息。
void _postCommand(int command) {
  if (!Platform.isWindows) return;
  try {
    final user32 = DynamicLibrary.open('user32.dll');
    final getForegroundWindow = user32
        .lookupFunction<IntPtr Function(), int Function()>(
          'GetForegroundWindow',
        );
    final postMessage = user32
        .lookupFunction<
          Int32 Function(IntPtr, Uint32, IntPtr, IntPtr),
          int Function(int, int, int, int)
        >('PostMessageW');
    final hwnd = getForegroundWindow();
    if (hwnd == 0) return;
    const wmSysCommand = 0x0112;
    postMessage(hwnd, wmSysCommand, command, 0);
  } catch (_) {}
}

void minimizeWindow() => _postCommand(0xF020); // SC_MINIMIZE
void closeWindow() => _postCommand(0xF060); // SC_CLOSE

/// 真退出（结束进程），不是最小化。
void quitApp() {
  try {
    exit(0);
  } catch (_) {
    closeWindow();
  }
}
