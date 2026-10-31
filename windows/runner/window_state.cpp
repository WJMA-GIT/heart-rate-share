#include "window_state.h"

#include <cstdio>
#include <cwchar>
#include <string>

#include "diagnostics.h"

namespace {

// 至少在某个工作区里留这么多像素，用户才抓得住窗口（多显示器拔掉一台靠它兜底）。
constexpr LONG kMinVisible = 64;
constexpr LONG kMinWidth = 200;
constexpr LONG kMinHeight = 150;

RECT g_probe{};
bool g_visible = false;

BOOL CALLBACK ProbeMonitor(HMONITOR, HDC, LPRECT work, LPARAM) {
  const LONG overlap_x =
      (g_probe.right < work->right ? g_probe.right : work->right) -
      (g_probe.left > work->left ? g_probe.left : work->left);
  const LONG overlap_y =
      (g_probe.bottom < work->bottom ? g_probe.bottom : work->bottom) -
      (g_probe.top > work->top ? g_probe.top : work->top);
  if (overlap_x >= kMinVisible && overlap_y >= kMinVisible) {
    g_visible = true;
    return FALSE;
  }
  return TRUE;
}

bool OnSomeMonitor(const RECT& rect) {
  g_probe = rect;
  g_visible = false;
  ::EnumDisplayMonitors(nullptr, nullptr, ProbeMonitor, 0);
  return g_visible;
}

std::wstring StatePath() {
  wchar_t local[MAX_PATH] = {0};
  if (::GetEnvironmentVariableW(L"LOCALAPPDATA", local, MAX_PATH) == 0) return {};
  const std::wstring dir = std::wstring(local) + L"\\heartrate";
  ::CreateDirectoryW(dir.c_str(), nullptr);
  return dir + L"\\window.state";
}

}  // namespace

namespace hrs {

bool LoadWindowRect(RECT* rect, bool* maximized) {
  const std::wstring path = StatePath();
  if (path.empty()) return false;
  FILE* file = nullptr;
  if (::_wfopen_s(&file, path.c_str(), L"r") != 0 || file == nullptr) return false;
  wchar_t line[128] = {0};
  const wchar_t* read = std::fgetws(line, 128, file);
  std::fclose(file);
  if (read == nullptr) return false;
  int x = 0;
  int y = 0;
  int width = 0;
  int height = 0;
  int is_maximized = 0;
  if (std::swscanf_s(line, L"%d %d %d %d %d", &x, &y, &width, &height, &is_maximized) != 5) {
    return false;
  }
  if (width < kMinWidth || height < kMinHeight) return false;
  const RECT candidate{x, y, x + width, y + height};
  if (!OnSomeMonitor(candidate)) {
    Log("window: saved rect on a missing monitor, fallback to primary");
    return false;
  }
  *rect = candidate;
  *maximized = is_maximized != 0;
  return true;
}

void SaveWindowRect(HWND window) {
  if (window == nullptr) return;
  RECT rect{};
  int is_maximized = 0;
  WINDOWPLACEMENT placement{};
  placement.length = sizeof(placement);
  if (::GetWindowPlacement(window, &placement)) {
    rect = placement.rcNormalPosition;
    is_maximized = placement.showCmd == SW_SHOWMAXIMIZED ? 1 : 0;
  }
  if (rect.right - rect.left < kMinWidth || rect.bottom - rect.top < kMinHeight) {
    if (!::GetWindowRect(window, &rect)) return;
  }
  const std::wstring path = StatePath();
  if (path.empty()) return;
  FILE* file = nullptr;
  if (::_wfopen_s(&file, path.c_str(), L"w") != 0 || file == nullptr) return;
  std::fwprintf(file, L"%ld %ld %ld %ld %d\n", rect.left, rect.top, rect.right - rect.left,
                rect.bottom - rect.top, is_maximized);
  std::fclose(file);
  Log("window: geometry saved");
}

}  // namespace hrs
