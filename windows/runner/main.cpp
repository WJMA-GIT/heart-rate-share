#include <flutter/dart_project.h>
#include <flutter/flutter_view_controller.h>
#include <windows.h>

#include <cstdio>
#include <cstring>
#include <cwchar>
#include <string>

#include "diagnostics.h"
#include "flutter_window.h"
#include "utils.h"

namespace {

using hrs::Log;

std::string Utf8(const std::wstring& wide) {
  if (wide.empty()) return {};
  const int size =
      ::WideCharToMultiByte(CP_UTF8, 0, wide.c_str(), -1, nullptr, 0, nullptr, nullptr);
  std::string out(size > 0 ? size - 1 : 0, '\0');
  if (size > 1) {
    ::WideCharToMultiByte(CP_UTF8, 0, wide.c_str(), -1, out.data(), size, nullptr, nullptr);
  }
  return out;
}

bool Exists(const std::wstring& path) {
  return ::GetFileAttributesW(path.c_str()) != INVALID_FILE_ATTRIBUTES;
}

void ShowFatalBox(const std::string& detail) {
  const std::wstring msg = L"共享心率启动失败。\n\n" + std::wstring(detail.begin(), detail.end()) +
                           L"\n\n日志目录：%LOCALAPPDATA%\\heartrate\\logs\n"
                           L"请把 startup.log / crash.log 发回给作者。";
  ::MessageBoxW(nullptr, msg.c_str(), L"共享心率", MB_ICONERROR | MB_OK);
}

LONG WINAPI CrashHandler(EXCEPTION_POINTERS* info) {
  char buffer[512] = {0};
  const DWORD code = info && info->ExceptionRecord ? info->ExceptionRecord->ExceptionCode : 0;
  const void* address =
      info && info->ExceptionRecord ? info->ExceptionRecord->ExceptionAddress : nullptr;
  _snprintf_s(buffer, sizeof(buffer), _TRUNCATE, "CRASH exception=0x%08lX address=%p",
              static_cast<unsigned long>(code), address);
  Log("crash", buffer);
  ShowFatalBox(buffer);
  return EXCEPTION_EXECUTE_HANDLER;
}

// 悬浮窗样式：无边框 + 分层颜色键透明 + 置顶 + 不进任务栏。
// 全部在窗口 Show 之前完成，只设一次；任何一步失败都只记日志、退化为不透明。
void ApplyOverlayStyles(HWND hwnd) {
  if (hwnd == nullptr) {
    Log("overlay: hwnd null, skip");
    return;
  }
  const LONG_PTR style = ::GetWindowLongPtr(hwnd, GWL_STYLE);
  ::SetWindowLongPtr(
      hwnd, GWL_STYLE,
      style & ~(WS_CAPTION | WS_THICKFRAME | WS_MINIMIZEBOX | WS_MAXIMIZEBOX | WS_SYSMENU));

  LONG_PTR ex_style = ::GetWindowLongPtr(hwnd, GWL_EXSTYLE);
  ex_style |= (WS_EX_LAYERED | WS_EX_TOOLWINDOW | WS_EX_TOPMOST);
  ex_style &= ~WS_EX_APPWINDOW;
  ::SetWindowLongPtr(hwnd, GWL_EXSTYLE, ex_style);

  const bool keyed =
      ::SetLayeredWindowAttributes(hwnd, RGB(1, 2, 3), 255, LWA_COLORKEY) != 0;
  ::SetWindowPos(hwnd, HWND_TOPMOST, 0, 0, 0, 0, SWP_NOMOVE | SWP_NOSIZE | SWP_FRAMECHANGED);
  Log(keyed ? "overlay: layered color-key ok" : "overlay: color-key failed, opaque");
}

bool HasFlag(const wchar_t* flag) { return ::wcsstr(::GetCommandLineW(), flag) != nullptr; }

bool EnvIsOne(const wchar_t* name) {
  wchar_t value[8] = {0};
  const DWORD len = ::GetEnvironmentVariableW(name, value, 8);
  return len > 0 && value[0] == L'1';
}

}  // namespace

int APIENTRY wWinMain(_In_ HINSTANCE instance, _In_opt_ HINSTANCE prev,
                      _In_ wchar_t* command_line, _In_ int show_command) {
  ::SetUnhandledExceptionFilter(CrashHandler);
  Log("---- launch ----");

  wchar_t exe_path[MAX_PATH] = {0};
  ::GetModuleFileNameW(nullptr, exe_path, MAX_PATH);
  Log("exe", Utf8(exe_path));

  std::wstring dir(exe_path);
  const size_t slash = dir.find_last_of(L'\\');
  if (slash != std::wstring::npos) dir = dir.substr(0, slash);
  const char* required[] = {"flutter_windows.dll", "data\\icudtl.dat", "data\\app.so",
                            "msvcp140.dll", "vcruntime140.dll", "vcruntime140_1.dll"};
  for (const char* name : required) {
    const std::wstring full = dir + L"\\" + std::wstring(name, name + strlen(name));
    Log("deps", std::string(name) + (Exists(full) ? " ok" : " MISSING"));
  }

  if (!::AttachConsole(ATTACH_PARENT_PROCESS) && ::IsDebuggerPresent()) {
    CreateAndAttachConsole();
  }
  ::CoInitializeEx(nullptr, COINIT_APARTMENTTHREADED);

  flutter::DartProject project(L"data");
  std::vector<std::string> command_line_arguments = GetCommandLineArguments();
  project.set_dart_entrypoint_arguments(std::move(command_line_arguments));

  FlutterWindow window(project);
  Win32Window::Point origin(120, 120);
  Win32Window::Size size(320, 220);
  if (!window.Create(L"heartrate", origin, size)) {
    Log("FATAL window.Create failed");
    ShowFatalBox("窗口创建失败（flutter_windows.dll / data 目录是否缺失？）");
    return EXIT_FAILURE;
  }
  window.SetQuitOnClose(true);

  HWND hwnd = window.GetHandle();
  Log("dpi", hwnd ? std::to_string(::GetDpiForWindow(hwnd)) : "unknown");

  const bool safe_mode = HasFlag(L"--safe-mode") || EnvIsOne(L"HEARTRATE_SAFE_MODE");
  const bool opaque_only = HasFlag(L"--opaque") || EnvIsOne(L"HEARTRATE_OPAQUE");
  Log("mode", std::string("safe=") + (safe_mode ? "1" : "0") +
                  " opaque=" + (opaque_only ? "1" : "0"));
  if (!safe_mode && !opaque_only) {
    ApplyOverlayStyles(hwnd);
  } else {
    Log("overlay: skipped (safe/opaque)");
  }

  Log("stage: entering message loop");
  ::MSG msg;
  while (::GetMessage(&msg, nullptr, 0, 0)) {
    ::TranslateMessage(&msg);
    ::DispatchMessage(&msg);
  }
  Log("stage: message loop exited");
  ::CoUninitialize();
  return EXIT_SUCCESS;
}
