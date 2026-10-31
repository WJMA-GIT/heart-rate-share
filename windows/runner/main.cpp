#include <flutter/dart_project.h>
#include <flutter/flutter_view_controller.h>
#include <windows.h>

#include "flutter_window.h"
#include "utils.h"

int APIENTRY wWinMain(_In_ HINSTANCE instance, _In_opt_ HINSTANCE prev,
                      _In_ wchar_t *command_line, _In_ int show_command) {
  // Attach to console when present (e.g., 'flutter run') or create a
  // new console when running with a debugger.
  if (!::AttachConsole(ATTACH_PARENT_PROCESS) && ::IsDebuggerPresent()) {
    CreateAndAttachConsole();
  }

  // Initialize COM, so that it is available for use in the library and/or
  // plugins.
  ::CoInitializeEx(nullptr, COINIT_APARTMENTTHREADED);

  flutter::DartProject project(L"data");

  std::vector<std::string> command_line_arguments =
      GetCommandLineArguments();

  project.set_dart_entrypoint_arguments(std::move(command_line_arguments));

  FlutterWindow window(project);
  // 悬浮窗形态：小窗起步，内容自适应；位置/尺寸由 Dart 侧（window_manager）接管。
  Win32Window::Point origin(120, 120);
  Win32Window::Size size(320, 220);
  if (!window.Create(L"heartrate", origin, size)) {
    return EXIT_FAILURE;
  }
  window.SetQuitOnClose(true);

  // ---- 悬浮窗窗口样式（在 Flutter 之外直接改 Win32 窗口属性）----
  // 1) 无边框：WS_POPUP 替代 WS_OVERLAPPEDWINDOW，去掉标题栏与边框；
  // 2) 分层 + 颜色键：把 RGB(1,2,3) 当作"透明色"，Dart 侧根容器刷成这个颜色 →
  //    背景 100% 透明，而文字/折线（其它颜色）保持完全不透明；
  //    LWA_COLORKEY 同时让透明区域的鼠标点击穿透到下层窗口；
  // 3) 置顶 + 工具窗口：始终在最前，且不出现在任务栏/Alt-Tab 里。
  HWND hwnd = window.GetHandle();
  LONG_PTR style = ::GetWindowLongPtr(hwnd, GWL_STYLE);
  style = style & ~(WS_CAPTION | WS_THICKFRAME | WS_MINIMIZEBOX | WS_MAXIMIZEBOX | WS_SYSMENU);
  ::SetWindowLongPtr(hwnd, GWL_STYLE, style);
  LONG_PTR ex_style = ::GetWindowLongPtr(hwnd, GWL_EXSTYLE);
  ex_style |= (WS_EX_LAYERED | WS_EX_TOOLWINDOW | WS_EX_TOPMOST);
  ex_style &= ~WS_EX_APPWINDOW;
  ::SetWindowLongPtr(hwnd, GWL_EXSTYLE, ex_style);
  ::SetLayeredWindowAttributes(hwnd, RGB(1, 2, 3), 255, LWA_COLORKEY);
  ::SetWindowPos(hwnd, HWND_TOPMOST, 0, 0, 0, 0,
                 SWP_NOMOVE | SWP_NOSIZE | SWP_FRAMECHANGED);
  ::ShowWindow(hwnd, SW_SHOWNORMAL);

  ::MSG msg;
  while (::GetMessage(&msg, nullptr, 0, 0)) {
    ::TranslateMessage(&msg);
    ::DispatchMessage(&msg);
  }

  ::CoUninitialize();
  return EXIT_SUCCESS;
}
