#include "win32_window.h"

#include <commctrl.h>  // SetWindowSubclass（挂在 Flutter 视图窗口上做命中测试）
#include <dwmapi.h>
#include <flutter_windows.h>
#include <windowsx.h>  // GET_X_LPARAM / GET_Y_LPARAM（WM_NCHITTEST 的鼠标坐标）

#include "diagnostics.h"
#include "resource.h"
#include "window_state.h"

namespace {

/// Window attribute that enables dark mode window decorations.
///
/// Redefined in case the developer's machine has a Windows SDK older than
/// version 10.0.22000.0.
/// See: https://docs.microsoft.com/windows/win32/api/dwmapi/ne-dwmapi-dwmwindowattribute
#ifndef DWMWA_USE_IMMERSIVE_DARK_MODE
#define DWMWA_USE_IMMERSIVE_DARK_MODE 20
#endif

constexpr const wchar_t kWindowClassName[] = L"FLUTTER_RUNNER_WIN32_WINDOW";

/// Registry key for app theme preference.
///
/// A value of 0 indicates apps should use dark mode. A non-zero or missing
/// value indicates apps should use light mode.
constexpr const wchar_t kGetPreferredBrightnessRegKey[] =
  L"Software\\Microsoft\\Windows\\CurrentVersion\\Themes\\Personalize";
constexpr const wchar_t kGetPreferredBrightnessRegValue[] = L"AppsUseLightTheme";

// The number of Win32Window objects that currently exist.
static int g_active_window_count = 0;

using EnableNonClientDpiScaling = BOOL __stdcall(HWND hwnd);

// Scale helper to convert logical scaler values to physical using passed in
// scale factor
int Scale(int source, double scale_factor) {
  return static_cast<int>(source * scale_factor);
}

// Dart 侧（lib/ui/win/win_drag.dart）推过来的三条窗口消息，不走任何插件：
//   WM_APP+1 wparam=宽 lparam=高   最小客户区（DIP，已含 UI 缩放）
//   WM_APP+2 wparam=1/0            透明精简态 进/出
//   WM_APP+3 wparam=宽 lparam=高   按内容改客户区（DIP）
constexpr UINT kMsgMinClientSize = WM_APP + 1;
constexpr UINT kMsgCompact = WM_APP + 2;
constexpr UINT kMsgClientSize = WM_APP + 3;
// WM_APP+4：Dart 上报可拖动区（DIP，相对窗口左上角）。wparam=(y<<16)|x，
// lparam=(h<<16)|w。只有这块返回 HTCAPTION，其余一律 HTCLIENT。
constexpr UINT kMsgDragRect = WM_APP + 4;

// 客户区尺寸（DIP）→ 窗口尺寸（物理像素）。客户端 == 整窗（WM_NCCALCSIZE 返回 0，
// 没有非客户区），所以这里只剩 DPI 折算，不再 AdjustWindowRectEx。
RECT ClientToWindow(HWND window, int dip_width, int dip_height) {
  const double scale = ::GetDpiForWindow(window) / 96.0;
  RECT rect{0, 0, static_cast<LONG>(dip_width * scale),
            static_cast<LONG>(dip_height * scale)};
  return rect;
}

void ResizeClientDip(HWND window, int dip_width, int dip_height) {
  if (window == nullptr || dip_width <= 0 || dip_height <= 0) return;
  const RECT rect = ClientToWindow(window, dip_width, dip_height);
  ::SetWindowPos(window, nullptr, 0, 0, rect.right - rect.left, rect.bottom - rect.top,
                 SWP_NOMOVE | SWP_NOZORDER | SWP_NOACTIVATE);
}

// 没有几何记录（首次运行 / 记录指向已拔掉的显示器）：主屏工作区居中。
void CenterOnPrimary(HWND window) {
  MONITORINFO monitor{};
  monitor.cbSize = sizeof(monitor);
  if (!::GetMonitorInfo(::MonitorFromWindow(window, MONITOR_DEFAULTTOPRIMARY), &monitor)) {
    return;
  }
  RECT rect{};
  if (!::GetWindowRect(window, &rect)) return;
  const LONG width = rect.right - rect.left;
  const LONG height = rect.bottom - rect.top;
  const LONG x =
      monitor.rcWork.left + ((monitor.rcWork.right - monitor.rcWork.left) - width) / 2;
  const LONG y =
      monitor.rcWork.top + ((monitor.rcWork.bottom - monitor.rcWork.top) - height) / 2;
  ::SetWindowPos(window, nullptr, x, y, 0, 0, SWP_NOSIZE | SWP_NOZORDER | SWP_NOACTIVATE);
}

// 无边框（去掉了 WS_CAPTION/WS_BORDER，且 WM_NCCALCSIZE 返回 0）的分层窗口：
// 系统没有非客户区可拖、可缩放，命中测试全得自己答：
//   - 外沿 8 DIP（和 96dpi 下系统边框同宽）→ HTLEFT/HTRIGHT/HTTOP/HTBOTTOM + 四角；
//   - Dart 上报的拖动区 → HTCAPTION（把手/空白带，见 win_app.dart 的拖动区上报）；
//   - 其余 → HTCLIENT，交给 Flutter 的按钮/输入框/滑杆。
// 拖动区必须由 Dart 明确给出：之前按"顶部 28 DIP 全宽"猜，结果把导航栏和
// 精简态行内控件一起判成了拖动区，鼠标一按就去拖窗、点击全丢。
constexpr int kResizeBorderDip = 8;

LRESULT ResizeEdgeFor(LONG x, LONG y, LONG width, LONG height, LONG border) {
  const bool left = x < border;
  const bool right = x >= width - border;
  const bool top = y < border;
  const bool bottom = y >= height - border;
  if (top && left) return HTTOPLEFT;
  if (top && right) return HTTOPRIGHT;
  if (bottom && left) return HTBOTTOMLEFT;
  if (bottom && right) return HTBOTTOMRIGHT;
  if (left) return HTLEFT;
  if (right) return HTRIGHT;
  if (top) return HTTOP;
  if (bottom) return HTBOTTOM;
  return HTCLIENT;
}

// Dynamically loads the |EnableNonClientDpiScaling| from the User32 module.
// This API is only needed for PerMonitor V1 awareness mode.
void EnableFullDpiSupportIfAvailable(HWND hwnd) {
  HMODULE user32_module = LoadLibraryA("User32.dll");
  if (!user32_module) {
    return;
  }
  auto enable_non_client_dpi_scaling =
      reinterpret_cast<EnableNonClientDpiScaling*>(
          GetProcAddress(user32_module, "EnableNonClientDpiScaling"));
  if (enable_non_client_dpi_scaling != nullptr) {
    enable_non_client_dpi_scaling(hwnd);
  }
  FreeLibrary(user32_module);
}

}  // namespace

// Manages the Win32Window's window class registration.
class WindowClassRegistrar {
 public:
  ~WindowClassRegistrar() = default;

  // Returns the singleton registrar instance.
  static WindowClassRegistrar* GetInstance() {
    if (!instance_) {
      instance_ = new WindowClassRegistrar();
    }
    return instance_;
  }

  // Returns the name of the window class, registering the class if it hasn't
  // previously been registered.
  const wchar_t* GetWindowClass();

  // Unregisters the window class. Should only be called if there are no
  // instances of the window.
  void UnregisterWindowClass();

 private:
  WindowClassRegistrar() = default;

  static WindowClassRegistrar* instance_;

  bool class_registered_ = false;
};

WindowClassRegistrar* WindowClassRegistrar::instance_ = nullptr;

const wchar_t* WindowClassRegistrar::GetWindowClass() {
  if (!class_registered_) {
    WNDCLASS window_class{};
    window_class.hCursor = LoadCursor(nullptr, IDC_ARROW);
    window_class.lpszClassName = kWindowClassName;
    window_class.style = CS_HREDRAW | CS_VREDRAW;
    window_class.cbClsExtra = 0;
    window_class.cbWndExtra = 0;
    window_class.hInstance = GetModuleHandle(nullptr);
    window_class.hIcon =
        LoadIcon(window_class.hInstance, MAKEINTRESOURCE(IDI_APP_ICON));
    window_class.hbrBackground = 0;
    window_class.lpszMenuName = nullptr;
    window_class.lpfnWndProc = Win32Window::WndProc;
    RegisterClass(&window_class);
    class_registered_ = true;
  }
  return kWindowClassName;
}

void WindowClassRegistrar::UnregisterWindowClass() {
  UnregisterClass(kWindowClassName, nullptr);
  class_registered_ = false;
}

Win32Window::Win32Window() {
  ++g_active_window_count;
}

Win32Window::~Win32Window() {
  --g_active_window_count;
  Destroy();
}

bool Win32Window::Create(const std::wstring& title,
                         const Point& origin,
                         const Size& size) {
  Destroy();

  const wchar_t* window_class =
      WindowClassRegistrar::GetInstance()->GetWindowClass();

  const POINT target_point = {static_cast<LONG>(origin.x),
                              static_cast<LONG>(origin.y)};
  HMONITOR monitor = MonitorFromPoint(target_point, MONITOR_DEFAULTTONEAREST);
  UINT dpi = FlutterDesktopGetDpiForMonitor(monitor);
  double scale_factor = dpi / 96.0;

  HWND window = CreateWindow(
      window_class, title.c_str(), WS_OVERLAPPEDWINDOW,
      Scale(origin.x, scale_factor), Scale(origin.y, scale_factor),
      Scale(size.width, scale_factor), Scale(size.height, scale_factor),
      nullptr, nullptr, GetModuleHandle(nullptr), this);

  if (!window) {
    return false;
  }

  // 几何记忆：上次的矩形按物理像素原样套用（和 Windows 自己的窗口记忆一致），
  // 没有记录或记录指向已断开的显示器时，主屏工作区居中。
  RECT saved{};
  bool maximized = false;
  if (hrs::LoadWindowRect(&saved, &maximized)) {
    ::SetWindowPos(window, nullptr, saved.left, saved.top, saved.right - saved.left,
                   saved.bottom - saved.top, SWP_NOZORDER | SWP_NOACTIVATE);
    start_maximized_ = maximized;
    hrs::Log("window: geometry restored");
  } else {
    CenterOnPrimary(window);
    hrs::Log("window: geometry default (centered)");
  }

  UpdateTheme(window);

  return OnCreate();
}

bool Win32Window::Show() {
  return ShowWindow(window_handle_,
                    start_maximized_ ? SW_SHOWMAXIMIZED : SW_SHOWNORMAL);
}

// static
LRESULT CALLBACK Win32Window::WndProc(HWND const window,
                                      UINT const message,
                                      WPARAM const wparam,
                                      LPARAM const lparam) noexcept {
  if (message == WM_NCCREATE) {
    auto window_struct = reinterpret_cast<CREATESTRUCT*>(lparam);
    SetWindowLongPtr(window, GWLP_USERDATA,
                     reinterpret_cast<LONG_PTR>(window_struct->lpCreateParams));

    auto that = static_cast<Win32Window*>(window_struct->lpCreateParams);
    EnableFullDpiSupportIfAvailable(window);
    that->window_handle_ = window;
  } else if (Win32Window* that = GetThisFromHandle(window)) {
    return that->MessageHandler(window, message, wparam, lparam);
  }

  return DefWindowProc(window, message, wparam, lparam);
}

LRESULT
Win32Window::MessageHandler(HWND hwnd,
                            UINT const message,
                            WPARAM const wparam,
                            LPARAM const lparam) noexcept {
  switch (message) {
    case WM_DESTROY:
      // 精简态的尺寸是内容尺寸，落盘会让下次以「三行高」启动，所以不记。
      if (!compact_) hrs::SaveWindowRect(hwnd);
      window_handle_ = nullptr;
      Destroy();
      if (quit_on_close_) {
        PostQuitMessage(0);
      }
      return 0;

    case WM_GETMINMAXINFO: {
      auto* info = reinterpret_cast<MINMAXINFO*>(lparam);
      // 最小尺寸跟着 UI 缩放走（Dart 侧推过来的是 DIP），这里统一折成物理像素。
      const RECT min_rect = ClientToWindow(hwnd, min_client_width_, min_client_height_);
      info->ptMinTrackSize.x = min_rect.right - min_rect.left;
      info->ptMinTrackSize.y = min_rect.bottom - min_rect.top;
      // 最大不超过当前显示器工作区：不给拖到屏幕外/盖住任务栏的机会。
      MONITORINFO monitor{};
      monitor.cbSize = sizeof(monitor);
      if (::GetMonitorInfo(::MonitorFromWindow(hwnd, MONITOR_DEFAULTTONEAREST),
                           &monitor)) {
        info->ptMaxTrackSize.x = monitor.rcWork.right - monitor.rcWork.left;
        info->ptMaxTrackSize.y = monitor.rcWork.bottom - monitor.rcWork.top;
      }
      return 0;
    }

    case kMsgMinClientSize:
      min_client_width_ = static_cast<int>(wparam);
      min_client_height_ = static_cast<int>(lparam);
      EnforceMinClientSize();
      return 0;

    case kMsgCompact:
      ApplyCompact(wparam != 0);
      return 0;

    case kMsgClientSize:
      ResizeClientDip(hwnd, static_cast<int>(wparam), static_cast<int>(lparam));
      return 0;

    case kMsgDragRect: {
      const double scale = ::GetDpiForWindow(hwnd) / 96.0;
      const int dip_x = static_cast<int>(LOWORD(wparam));
      const int dip_y = static_cast<int>(HIWORD(wparam));
      const int dip_w = static_cast<int>(LOWORD(lparam));
      const int dip_h = static_cast<int>(HIWORD(lparam));
      has_drag_rect_ = dip_w > 0 && dip_h > 0;
      drag_rect_.left = static_cast<LONG>(dip_x * scale);
      drag_rect_.top = static_cast<LONG>(dip_y * scale);
      drag_rect_.right = static_cast<LONG>((dip_x + dip_w) * scale);
      drag_rect_.bottom = static_cast<LONG>((dip_y + dip_h) * scale);
      // 给冒烟用：CI 直接读这行，按同一份矩形去断言命中结果。
      hrs::Log("hit: drag rect",
               "x=" + std::to_string(dip_x) + " y=" + std::to_string(dip_y) +
                   " w=" + std::to_string(dip_w) + " h=" + std::to_string(dip_h));
      return 0;
    }

    case WM_NCHITTEST:
      return HitTestWindow(lparam);

    case WM_NCCALCSIZE:
      // 客户区 == 整个窗口：不留任何非客户区，标题栏/边框连一条细线都没有。
      // 缩放和拖动全靠上面的 WM_NCHITTEST（`HitTestWindow`）。
      if (wparam != FALSE) return 0;
      break;

    case WM_DPICHANGED: {
      auto newRectSize = reinterpret_cast<RECT*>(lparam);
      LONG newWidth = newRectSize->right - newRectSize->left;
      LONG newHeight = newRectSize->bottom - newRectSize->top;

      SetWindowPos(hwnd, nullptr, newRectSize->left, newRectSize->top, newWidth,
                   newHeight, SWP_NOZORDER | SWP_NOACTIVATE);

      return 0;
    }
    case WM_SIZE:
      // 尺寸一变就把视图重新铺满客户区（含精简态改尺寸、DPI 切换后的重排）。
      SyncChildToClient();
      return 0;

    case WM_ACTIVATE:
      if (child_content_ != nullptr) {
        SetFocus(child_content_);
      }
      return 0;

    case WM_DWMCOLORIZATIONCOLORCHANGED:
      UpdateTheme(hwnd);
      return 0;
  }

  return DefWindowProc(window_handle_, message, wparam, lparam);
}

void Win32Window::Destroy() {
  OnDestroy();

  if (window_handle_) {
    DestroyWindow(window_handle_);
    window_handle_ = nullptr;
  }
  if (g_active_window_count == 0) {
    WindowClassRegistrar::GetInstance()->UnregisterWindowClass();
  }
}

Win32Window* Win32Window::GetThisFromHandle(HWND const window) noexcept {
  return reinterpret_cast<Win32Window*>(
      GetWindowLongPtr(window, GWLP_USERDATA));
}

// Flutter 视图必须严格铺满客户区：WM_NCCALCSIZE 把客户区放大到整窗后，
// 视图还按旧尺寸摆就会"UI 缩在中间一块、还能在窗口里移动"。
void Win32Window::SyncChildToClient() {
  if (child_content_ == nullptr || window_handle_ == nullptr) return;
  RECT client = GetClientArea();
  ::SetWindowPos(child_content_, nullptr, client.left, client.top,
                 client.right - client.left, client.bottom - client.top,
                 SWP_NOZORDER | SWP_NOACTIVATE | SWP_NOCOPYBITS);
}

void Win32Window::SetChildContent(HWND content) {
  child_content_ = content;
  SetParent(content, window_handle_);
  SyncChildToClient();

  // 视图窗口盖满客户区，鼠标命中只会问它：不挂这个子类过程，缩放/拖拽带了
  // 就永远收不到 WM_NCHITTEST（这就是「保留 WS_THICKFRAME 也拉不动」的真相）。
  if (!::SetWindowSubclass(content, &Win32Window::HitTestSubclass, 1,
                           reinterpret_cast<DWORD_PTR>(this))) {
    hrs::Log("window: SetWindowSubclass failed, resize/drag by frame only");
  }

  SetFocus(child_content_);
}

RECT Win32Window::GetClientArea() {
  RECT frame;
  GetClientRect(window_handle_, &frame);
  return frame;
}

HWND Win32Window::GetHandle() {
  return window_handle_;
}

void Win32Window::SetQuitOnClose(bool quit_on_close) {
  quit_on_close_ = quit_on_close;
}

// 命中测试的唯一实现：顶层窗口和 Flutter 视图（子类过程）都走它。
LRESULT Win32Window::HitTestWindow(LPARAM lparam) {
  if (window_handle_ == nullptr) return HTCLIENT;
  RECT rect{};
  if (!::GetWindowRect(window_handle_, &rect)) return HTCLIENT;
  const LONG width = rect.right - rect.left;
  const LONG height = rect.bottom - rect.top;
  const LONG x = GET_X_LPARAM(lparam) - rect.left;
  const LONG y = GET_Y_LPARAM(lparam) - rect.top;
  if (x < 0 || y < 0 || x >= width || y >= height) return HTNOWHERE;

  const double scale = ::GetDpiForWindow(window_handle_) / 96.0;
  // 精简态按内容自适应，不给缩放；最大化时也不给（先还原成普通窗口再说）。
  if (!compact_ && !::IsZoomed(window_handle_)) {
    const LONG border = static_cast<LONG>(kResizeBorderDip * scale);
    const LRESULT edge = ResizeEdgeFor(x, y, width, height, border);
    if (edge != HTCLIENT) return edge;
  }
  // x/y 已经是窗口内坐标；drag_rect_ 同样是窗口内坐标（DIP×DPI），直接比。
  if (has_drag_rect_ && x >= drag_rect_.left && x < drag_rect_.right &&
      y >= drag_rect_.top && y < drag_rect_.bottom) {
    return HTCAPTION;
  }
  return HTCLIENT;
}

LRESULT CALLBACK Win32Window::HitTestSubclass(HWND hwnd, UINT message,
                                              WPARAM wparam, LPARAM lparam,
                                              UINT_PTR id, DWORD_PTR ref) {
  auto* that = reinterpret_cast<Win32Window*>(ref);
  if (message == WM_NCHITTEST && that != nullptr) {
    return that->HitTestWindow(lparam);
  }
  return ::DefSubclassProc(hwnd, message, wparam, lparam);
}

// 用户把 UI 放大到 1.6 后最小尺寸跟着变大：已经比最小还小的窗口现场撑开，
// 否则「放大后被裁」还是会发生。
void Win32Window::EnforceMinClientSize() {
  if (window_handle_ == nullptr) return;
  RECT client{};
  if (!::GetClientRect(window_handle_, &client)) return;
  const double scale = ::GetDpiForWindow(window_handle_) / 96.0;
  const int width = static_cast<int>((client.right - client.left) / scale);
  const int height = static_cast<int>((client.bottom - client.top) / scale);
  if (width >= min_client_width_ && height >= min_client_height_) return;
  ResizeClientDip(window_handle_, width > min_client_width_ ? width : min_client_width_,
                  height > min_client_height_ ? height : min_client_height_);
}

// 透明精简态：进之前记下完整界面的矩形，退出时原样还原。
void Win32Window::ApplyCompact(bool compact) {
  if (window_handle_ == nullptr || compact == compact_) return;
  compact_ = compact;
  if (compact) {
    // 最大化状态先还原：否则记下来的是铺满屏幕的矩形，退出精简态也回不到原样。
    if (::IsZoomed(window_handle_)) ::ShowWindow(window_handle_, SW_RESTORE);
    full_rect_ = {};
    ::GetWindowRect(window_handle_, &full_rect_);
    return;
  }
  if (full_rect_.right > full_rect_.left && full_rect_.bottom > full_rect_.top) {
    ::SetWindowPos(window_handle_, nullptr, full_rect_.left, full_rect_.top,
                   full_rect_.right - full_rect_.left,
                   full_rect_.bottom - full_rect_.top,
                   SWP_NOZORDER | SWP_NOACTIVATE);
    full_rect_ = {};
  }
}

bool Win32Window::OnCreate() {
  // No-op; provided for subclasses.
  return true;
}

void Win32Window::OnDestroy() {
  // No-op; provided for subclasses.
}

void Win32Window::UpdateTheme(HWND const window) {
  DWORD light_mode;
  DWORD light_mode_size = sizeof(light_mode);
  LSTATUS result = RegGetValue(HKEY_CURRENT_USER, kGetPreferredBrightnessRegKey,
                               kGetPreferredBrightnessRegValue,
                               RRF_RT_REG_DWORD, nullptr, &light_mode,
                               &light_mode_size);

  if (result == ERROR_SUCCESS) {
    BOOL enable_dark_mode = light_mode == 0;
    DwmSetWindowAttribute(window, DWMWA_USE_IMMERSIVE_DARK_MODE,
                          &enable_dark_mode, sizeof(enable_dark_mode));
  }
}
