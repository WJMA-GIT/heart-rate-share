#include <dwmapi.h>
#include <flutter/dart_project.h>
#include <flutter/flutter_view_controller.h>
#include <windows.h>

#include <cstdio>
#include <cstring>
#include <cwchar>
#include <string>

#include "diagnostics.h"

#ifndef HRS_VERSION
#define HRS_VERSION "1.0.6"
#endif
#include "flutter_window.h"
#include "overlay_window.h"
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

// UTF-8 → 宽字符。**不能**逐字节 widen（那就是 "å…±äº«" 乱码的来源）。
std::wstring Widen(const std::string& utf8) {
  if (utf8.empty()) return {};
  const int size = ::MultiByteToWideChar(CP_UTF8, 0, utf8.c_str(),
                                        static_cast<int>(utf8.size()), nullptr, 0);
  if (size <= 0) return L"(unprintable)";
  std::wstring out(static_cast<size_t>(size), L'\0');
  ::MultiByteToWideChar(CP_UTF8, 0, utf8.c_str(), static_cast<int>(utf8.size()), out.data(),
                        size);
  return out;
}

// 弹窗只放三行：产品名+版本 / 异常摘要 / 日志目录，统一 MessageBoxW。
void ShowFatalBox(const std::string& summary_utf8) {
  wchar_t log_dir[MAX_PATH] = {0};
  ::GetEnvironmentVariableW(L"LOCALAPPDATA", log_dir, MAX_PATH);
  std::wstring message = L"共享心率 " + Widen(HRS_VERSION) + L"\n" + Widen(summary_utf8) +
                         L"\n日志：";
  message += log_dir;
  message += L"\\heartrate\\logs\\startup.log";
  ::MessageBoxW(nullptr, message.c_str(), L"共享心率", MB_ICONERROR | MB_OK);
}

// 出错模块名与模块内偏移：这样弹窗/日志能直接指到 window_manager_plugin.dll:0x…b2af
// 这种粒度，不用再让用户去翻事件查看器。
void DescribeFault(const void* address, std::string* module, unsigned long long* offset) {
  *module = "unknown";
  *offset = 0;
  if (address == nullptr) return;
  HMODULE base = nullptr;
  if (::GetModuleHandleExW(GET_MODULE_HANDLE_EX_FLAG_FROM_ADDRESS |
                               GET_MODULE_HANDLE_EX_FLAG_UNCHANGED_REFCOUNT,
                           reinterpret_cast<LPCWSTR>(address), &base) &&
      base != nullptr) {
    wchar_t path[MAX_PATH] = {0};
    if (::GetModuleFileNameW(base, path, MAX_PATH) > 0) {
      std::wstring full(path);
      const size_t slash = full.find_last_of(L'\\');
      *module = Utf8(slash == std::wstring::npos ? full : full.substr(slash + 1));
    }
    *offset = reinterpret_cast<unsigned long long>(address) -
              reinterpret_cast<unsigned long long>(base);
  }
}

LONG WINAPI CrashHandler(EXCEPTION_POINTERS* info) {
  const DWORD code = info && info->ExceptionRecord ? info->ExceptionRecord->ExceptionCode : 0;
  const void* address =
      info && info->ExceptionRecord ? info->ExceptionRecord->ExceptionAddress : nullptr;
  std::string module;
  unsigned long long offset = 0;
  DescribeFault(address, &module, &offset);
  char summary[256] = {0};
  _snprintf_s(summary, sizeof(summary), _TRUNCATE,
              "exception=0x%08lX module=%s offset=0x%llX", static_cast<unsigned long>(code),
              module.c_str(), offset);
  Log("crash", summary);
  ShowFatalBox(summary);
  return EXCEPTION_EXECUTE_HANDLER;
}

// 主窗口：无边框（用户不要标题栏），但**不置顶、不透明、非分层**。
// 只去掉标题栏与系统菜单，保留 WS_THICKFRAME 让系统边框参与命中/缩放。
void MakeMainWindowFrameless(HWND hwnd) {
  if (hwnd == nullptr) return;
  const LONG_PTR style = ::GetWindowLongPtr(hwnd, GWL_STYLE);
  ::SetWindowLongPtr(hwnd, GWL_STYLE, style & ~(WS_CAPTION | WS_SYSMENU));
  const COLORREF no_border = 0xFFFFFFFE;  // DWMWA_COLOR_NONE
  ::DwmSetWindowAttribute(hwnd, 34 /* DWMWA_BORDER_COLOR */, &no_border,
                          sizeof(no_border));
  ::SetWindowPos(hwnd, nullptr, 0, 0, 0, 0,
                 SWP_NOMOVE | SWP_NOSIZE | SWP_NOZORDER | SWP_FRAMECHANGED);
  Log("main: frameless, not topmost, not layered");
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
  // 预览开关统一翻译成环境变量（和 HEARTRATE_SAFE_MODE 一样），loader 不透传参数时也有效。
  if (HasFlag(L"--connected-preview") || EnvIsOne(L"HEARTRATE_PREVIEW")) {
    ::SetEnvironmentVariableW(L"HEARTRATE_PREVIEW", L"1");
  }
  project.set_dart_entrypoint_arguments(std::move(command_line_arguments));

  FlutterWindow window(project);
  // 主窗口默认 900×700，可缩放；位置/尺寸优先用上次退出的记录。
  Win32Window::Point origin(120, 120);
  Win32Window::Size size(900, 700);
  if (!window.Create(L"heartrate", origin, size)) {
    Log("FATAL window.Create failed");
    ShowFatalBox("窗口创建失败（flutter_windows.dll / data 目录是否缺失？）");
    return EXIT_FAILURE;
  }
  window.SetQuitOnClose(true);
  HWND hwnd = window.GetHandle();
  Log("dpi", hwnd ? std::to_string(::GetDpiForWindow(hwnd)) : "unknown");

  const bool safe_mode = HasFlag(L"--safe-mode") || EnvIsOne(L"HEARTRATE_SAFE_MODE");
  const bool preview = EnvIsOne(L"HEARTRATE_PREVIEW");
  Log("mode", std::string("safe=") + (safe_mode ? "1" : "0") + " preview=" +
                  (preview ? "1" : "0"));
  MakeMainWindowFrameless(hwnd);

  // 悬浮窗：独立的原生窗口，只在「已连接」时显示（Dart 通过通道控制）。
  hrs::OverlayWindow overlay;
  if (overlay.Create(hwnd)) {
    window.set_overlay(&overlay);
  } else {
    Log("overlay: create failed, 悬浮窗不可用（主界面不受影响）");
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
