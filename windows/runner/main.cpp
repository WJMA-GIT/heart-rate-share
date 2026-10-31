#include <flutter/dart_project.h>
#include <flutter/flutter_view_controller.h>
#include <windows.h>

#include <cstdio>
#include <cstring>
#include <cwchar>
#include <string>

#include "flutter_window.h"
#include "utils.h"

namespace {

// 崩溃/启动诊断：写到 %LOCALAPPDATA%\heartrate\logs\startup.log / crash.log。
// 为什么这么早：Flutter/Dart 还没跑起来时的问题（缺 DLL、缺 data、DWM 失败）
// 只能靠原生侧记录；loader 级失败（缺 VC++ 运行时）连这里都进不来，所以包里同时
// 带了 VC++ 运行时 DLL。
std::wstring LogDir() {
  wchar_t buffer[MAX_PATH] = {0};
  const DWORD len = ::GetEnvironmentVariableW(L"LOCALAPPDATA", buffer, MAX_PATH);
  std::wstring dir = (len > 0 && len < MAX_PATH) ? std::wstring(buffer, len) : std::wstring(L".");
  dir += L"\\heartrate\\logs";
  ::CreateDirectoryW((dir.substr(0, dir.size() - 5)).c_str(), nullptr);  // ...\heartrate
  ::CreateDirectoryW(dir.c_str(), nullptr);
  return dir;
}

void AppendLog(const wchar_t* file, const std::string& text) {
  const std::wstring path = LogDir() + L"\\" + file;
  FILE* fp = nullptr;
  if (_wfopen_s(&fp, path.c_str(), L"a, ccs=UTF-8") != 0 || fp == nullptr) return;
  SYSTEMTIME st;
  ::GetLocalTime(&st);
  fwprintf(fp, L"[%04d-%02d-%02d %02d:%02d:%02d] ", st.wYear, st.wMonth, st.wDay, st.wHour,
           st.wMinute, st.wSecond);
  fwprintf(fp, L"%hs\n", text.c_str());
  fclose(fp);
}

std::string Utf8(const std::wstring& wide) {
  if (wide.empty()) return {};
  const int size = ::WideCharToMultiByte(CP_UTF8, 0, wide.c_str(), -1, nullptr, 0, nullptr, nullptr);
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
  const std::wstring msg =
      L"共享心率启动失败。\n\n" + std::wstring(detail.begin(), detail.end()) +
      L"\n\n日志目录：%LOCALAPPDATA%\\heartrate\\logs\n"
      L"请把 startup.log / crash.log 发回给作者。";
  ::MessageBoxW(nullptr, msg.c_str(), L"共享心率", MB_ICONERROR | MB_OK);
}

LONG WINAPI CrashHandler(EXCEPTION_POINTERS* info) {
  char buffer[512] = {0};
  const DWORD code = info && info->ExceptionRecord ? info->ExceptionRecord->ExceptionCode : 0;
  const void* address =
      info && info->ExceptionRecord ? info->ExceptionRecord->ExceptionAddress : nullptr;
  _snprintf_s(buffer, sizeof(buffer), _TRUNCATE,
              "CRASH exception=0x%08lX address=%p", static_cast<unsigned long>(code), address);
  AppendLog(L"crash.log", buffer);
  ShowFatalBox(buffer);
  return EXCEPTION_EXECUTE_HANDLER;
}

// 悬浮窗样式：无边框 + 分层颜色键透明 + 置顶 + 不进任务栏。
// 每一步都容错：任何一步失败都只记日志，不影响窗口正常显示（宁可不透明，不能起不来）。
void ApplyOverlayStyles(HWND hwnd) {
  if (hwnd == nullptr) {
    AppendLog(L"startup.log", "overlay: hwnd is null, skip styles");
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

  bool keyed = false;
  if (::SetLayeredWindowAttributes(hwnd, RGB(1, 2, 3), 255, LWA_COLORKEY) != 0) {
    keyed = true;
  } else {
    // 极少数机器/远程桌面不允许颜色键：退回不透明窗口，但功能照常可用。
    AppendLog(L"startup.log", "overlay: SetLayeredWindowAttributes failed, opaque fallback");
  }
  ::SetWindowPos(hwnd, HWND_TOPMOST, 0, 0, 0, 0, SWP_NOMOVE | SWP_NOSIZE | SWP_FRAMECHANGED);
  // 不在这里 ShowWindow：模板是在**首帧回调**里 Show()。早期版本在这里先 Show 一次、
  // 回调里又 Show 一次，样式与显示在用户回调里反复切换，配合 window_manager 的
  // WndProc 子类化直接 0xC000041D。现在样式在 Show 之前设好，只 Show 一次。
  AppendLog(L"startup.log", keyed ? "overlay: layered color-key ok" : "overlay: opaque");
}

bool HasFlag(const wchar_t* flag) {
  return ::wcsstr(::GetCommandLineW(), flag) != nullptr;
}

bool EnvIsOne(const wchar_t* name) {
  wchar_t value[8] = {0};
  const DWORD len = ::GetEnvironmentVariableW(name, value, 8);
  return len > 0 && value[0] == L'1';
}

}  // namespace

int APIENTRY wWinMain(_In_ HINSTANCE instance, _In_opt_ HINSTANCE prev,
                      _In_ wchar_t *command_line, _In_ int show_command) {
  ::SetUnhandledExceptionFilter(CrashHandler);
  AppendLog(L"startup.log", "---- launch ----");

  wchar_t exe_path[MAX_PATH] = {0};
  ::GetModuleFileNameW(nullptr, exe_path, MAX_PATH);
  AppendLog(L"startup.log", "exe=" + Utf8(exe_path));

  // 依赖自检：缺任何一个都必然是"双击就退"，先把证据写下来。
  std::wstring dir(exe_path);
  const size_t slash = dir.find_last_of(L'\\');
  if (slash != std::wstring::npos) dir = dir.substr(0, slash);
  const char* required[] = {
      "flutter_windows.dll", "data\\icudtl.dat", "data\\app.so",
      // CRT 由 CI 一起打进包内；缺了它们进程在 loader 阶段就退（连日志都没有）。
      "msvcp140.dll", "vcruntime140.dll", "vcruntime140_1.dll"};
  for (const char* name : required) {
    const std::wstring full = dir + L"\\" + std::wstring(name, name + strlen(name));
    AppendLog(L"startup.log",
              std::string("deps: ") + name + (Exists(full) ? " ok" : " MISSING"));
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
    AppendLog(L"startup.log", "FATAL window.Create failed");
    ShowFatalBox("窗口创建失败（flutter_windows.dll / data 目录是否缺失？）");
    return EXIT_FAILURE;
  }
  window.SetQuitOnClose(true);

  HWND hwnd = window.GetHandle();
  UINT dpi = 96;
  if (hwnd != nullptr) dpi = ::GetDpiForWindow(hwnd);
  AppendLog(L"startup.log", "dpi=" + std::to_string(dpi));
  // 排查用逃生门（两个都认）：
  //   --safe-mode / HEARTRATE_SAFE_MODE=1  完全普通窗口（不分层、不置顶、不无边框）
  //   --opaque / HEARTRATE_OPAQUE=1        只关掉透明，保留无边框置顶
  const bool safe_mode = HasFlag(L"--safe-mode") || EnvIsOne(L"HEARTRATE_SAFE_MODE");
  const bool opaque_only = HasFlag(L"--opaque") || EnvIsOne(L"HEARTRATE_OPAQUE");
  AppendLog(L"startup.log", std::string("mode: safe=") + (safe_mode ? "1" : "0") +
                                 " opaque=" + (opaque_only ? "1" : "0"));
  if (safe_mode || opaque_only) {
    AppendLog(L"startup.log", "overlay: skipped (safe/opaque mode)");
  } else {
    ApplyOverlayStyles(hwnd);
  }

  AppendLog(L"startup.log", "entering message loop");
  ::MSG msg;
  while (::GetMessage(&msg, nullptr, 0, 0)) {
    ::TranslateMessage(&msg);
    ::DispatchMessage(&msg);
  }
  AppendLog(L"startup.log", "message loop exited");
  ::CoUninitialize();
  return EXIT_SUCCESS;
}
