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
void _postCommand(int command) => _post(0x0112, command, 0); // WM_SYSCOMMAND

void minimizeWindow() => _postCommand(0xF020); // SC_MINIMIZE
void closeWindow() => _postCommand(0xF060); // SC_CLOSE

// ---------------------------------------------------------------- 窗口尺寸

// 三条 WM_APP 消息，对应 windows/runner/win32_window.cpp 里的同名分支：
// 尺寸统一用 DIP 传，DPI 折算全部留在原生的 ClientToWindow 一处。
const int _wmAppMinClientSize = 0x8001;
const int _wmAppCompact = 0x8002;
const int _wmAppClientSize = 0x8003;
const int _wmAppDragRect = 0x8004;

/// 最小客户区（DIP）：720×480，乘当前 UI 缩放后由 runner 的 WM_GETMINMAXINFO 兜住。
void setWindowMinSize(double width, double height) =>
    _post(_wmAppMinClientSize, width.round(), height.round());

/// 透明精简态进/出：进的时候 runner 记下当前矩形，出去时原样还原。
void setCompactWindow(bool compact) => _post(_wmAppCompact, compact ? 1 : 0, 0);

/// 按内容改客户区（DIP）：精简态宽度按内容、高度按行数。
void setWindowClientSize(double width, double height) =>
    _post(_wmAppClientSize, width.round(), height.round());

/// 可拖动区（DIP，相对窗口左上角）：只有这块返回 HTCAPTION。
/// 必须显式给：按"空白区"猜会把按钮一起判成拖动区，点击就全丢。
void setWindowDragRect(double x, double y, double width, double height) => _post(
  _wmAppDragRect,
  (y.round() << 16) | (x.round() & 0xFFFF),
  (height.round() << 16) | (width.round() & 0xFFFF),
);

void _post(int message, int wparam, int lparam) {
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
    // 发给自己进程的前台窗口：点「连接」/拖缩放时窗口必然在前台。
    // shortcut: 首帧之前发出的消息可能丢（窗口还没显示），原生默认 720×480 兜底。
    postMessage(hwnd, message, wparam, lparam);
  } catch (_) {
    // 消息发不出去不影响功能（最小尺寸原生默认就是 720×480）
  }
}

/// 真退出（结束进程），不是最小化。
void quitApp() {
  try {
    exit(0);
  } catch (_) {
    closeWindow();
  }
}
