#include "overlay_window.h"

#include <gdiplus.h>
#include <windowsx.h>

#include <algorithm>
#include <cmath>

#include "diagnostics.h"

#pragma comment(lib, "gdiplus.lib")

namespace hrs {
namespace {

constexpr wchar_t kClassName[] = L"HRS_OVERLAY_WINDOW";

// 与 Dart 的 _CompactMetrics / OverlayMetrics 对齐（改一处要一起改）。
constexpr float kGutterDip = 16.0f;
constexpr float kNameWidthDip = 96.0f;
constexpr float kChartWidthDip = 72.0f;
constexpr float kGapDip = 6.0f;
constexpr float kPaddingDip = 8.0f;
constexpr float kButtonDip = 24.0f;
constexpr float kVerticalPaddingDip = 6.0f;

ULONG_PTR g_gdiplus_token = 0;
int g_gdiplus_refs = 0;

void EnsureGdiplus() {
  if (g_gdiplus_refs++ > 0) return;
  Gdiplus::GdiplusStartupInput input;
  if (Gdiplus::GdiplusStartup(&g_gdiplus_token, &input, nullptr) != Gdiplus::Ok) {
    g_gdiplus_token = 0;
  }
}

void ReleaseGdiplus() {
  if (--g_gdiplus_refs > 0) return;
  if (g_gdiplus_token != 0) {
    Gdiplus::GdiplusShutdown(g_gdiplus_token);
    g_gdiplus_token = 0;
  }
}

float DipToPx(HWND hwnd, float dip) {
  return dip * static_cast<float>(::GetDpiForWindow(hwnd)) / 96.0f;
}

}  // namespace

OverlayWindow::~OverlayWindow() { ReleaseGdiplus(); }

bool OverlayWindow::Create(HWND notify) {
  notify_ = notify;
  EnsureGdiplus();

  WNDCLASSEX wc{};
  wc.cbSize = sizeof(wc);
  wc.lpfnWndProc = &OverlayWindow::WndProc;
  wc.hInstance = ::GetModuleHandle(nullptr);
  wc.lpszClassName = kClassName;
  wc.hCursor = ::LoadCursor(nullptr, IDC_ARROW);
  if (!::RegisterClassExW(&wc) && ::GetLastError() != ERROR_CLASS_ALREADY_EXISTS) {
    Log("overlay: RegisterClassEx failed");
    return false;
  }

  hwnd_ = ::CreateWindowExW(
      WS_EX_LAYERED | WS_EX_TOPMOST | WS_EX_TOOLWINDOW | WS_EX_NOACTIVATE,
      kClassName, L"heartrate-overlay", WS_POPUP, 0, 0, 10, 10, nullptr, nullptr,
      ::GetModuleHandle(nullptr), this);
  if (hwnd_ == nullptr) {
    Log("overlay: CreateWindowEx failed");
    return false;
  }
  Log("overlay: created (layered+topmost)");
  return true;
}

void OverlayWindow::SetRows(std::vector<OverlayRow> rows, float font_dip) {
  rows_ = std::move(rows);
  font_dip_ = font_dip > 8.0f ? font_dip : 8.0f;
  ResizeToContent();
  if (visible_) Render();
}

void OverlayWindow::Show() {
  if (hwnd_ == nullptr) return;
  Log("overlay: show begin");
  ResizeToContent();
  Log("overlay: resized");
  Render();
  Log("overlay: rendered");
  ::SetWindowPos(hwnd_, HWND_TOPMOST, 0, 0, 0, 0,
                 SWP_NOMOVE | SWP_NOSIZE | SWP_NOACTIVATE | SWP_SHOWWINDOW);
  ::ShowWindow(hwnd_, SW_SHOWNOACTIVATE);
  if (!visible_) Log("overlay: shown");
  visible_ = true;
}

void OverlayWindow::Hide() {
  if (hwnd_ == nullptr) return;
  ::ShowWindow(hwnd_, SW_HIDE);
  Log(visible_ ? "overlay: hidden" : "overlay: hidden (was not visible)");
  visible_ = false;
}

void OverlayWindow::ResizeToContent() {
  if (hwnd_ == nullptr) return;
  const float scale = static_cast<float>(::GetDpiForWindow(hwnd_)) / 96.0f;
  const float row_height = std::max(22.0f, font_dip_ * 1.4f) * scale;
  const float bpm_width = std::max(48.0f, font_dip_ * 1.86f) * scale;
  const float width = (kGutterDip + kNameWidthDip + kGapDip + kChartWidthDip +
                       kGapDip + kButtonDip + kPaddingDip * 2.0f) *
                          scale +
                      bpm_width;
  const int rows = rows_.empty() ? 1 : static_cast<int>(rows_.size());
  const float height =
      rows * row_height + kVerticalPaddingDip * 2.0f * scale;
  RECT current{};
  ::GetWindowRect(hwnd_, &current);
  if (current.right - current.left != static_cast<int>(width) ||
      current.bottom - current.top != static_cast<int>(height)) {
    ::SetWindowPos(hwnd_, HWND_TOPMOST, current.left, current.top,
                   static_cast<int>(width), static_cast<int>(height),
                   SWP_NOACTIVATE);
  }
}

void OverlayWindow::Render() {
  if (hwnd_ == nullptr) return;
  const float scale = static_cast<float>(::GetDpiForWindow(hwnd_)) / 96.0f;
  RECT rect{};
  ::GetWindowRect(hwnd_, &rect);
  const int width = rect.right - rect.left;
  const int height = rect.bottom - rect.top;
  if (width <= 0 || height <= 0) return;

  HDC screen = ::GetDC(nullptr);
  HDC memory = ::CreateCompatibleDC(screen);
  BITMAPINFO info{};
  info.bmiHeader.biSize = sizeof(BITMAPINFOHEADER);
  info.bmiHeader.biWidth = width;
  info.bmiHeader.biHeight = -height;  // top-down
  info.bmiHeader.biPlanes = 1;
  info.bmiHeader.biBitCount = 32;
  info.bmiHeader.biCompression = BI_RGB;
  void* bits = nullptr;
  HBITMAP bitmap = ::CreateDIBSection(screen, &info, DIB_RGB_COLORS, &bits, nullptr, 0);
  if (bitmap == nullptr) {
    ::DeleteDC(memory);
    ::ReleaseDC(nullptr, screen);
    return;
  }
  HGDIOBJ old = ::SelectObject(memory, bitmap);

  {
    Gdiplus::Graphics g(memory);
    g.SetCompositingMode(Gdiplus::CompositingModeSourceCopy);
    g.SetSmoothingMode(Gdiplus::SmoothingModeAntiAlias);
    g.SetTextRenderingHint(Gdiplus::TextRenderingHintAntiAlias);
    g.Clear(Gdiplus::Color(0, 0, 0, 0));
    g.SetCompositingMode(Gdiplus::CompositingModeSourceOver);

    const float row_height = std::max(22.0f, font_dip_ * 1.4f) * scale;
    const float bpm_width = std::max(48.0f, font_dip_ * 1.86f) * scale;
    const float left = kPaddingDip * scale;
    const float top = kVerticalPaddingDip * scale;
    // 左侧 16 DIP 隐形拖动条：alpha=1 才收得到鼠标（全透明的像素是穿透的）。
    {
      Gdiplus::SolidBrush handle(Gdiplus::Color(1, 255, 255, 255));
      g.FillRectangle(&handle, Gdiplus::RectF(0, 0, kGutterDip * scale,
                                              static_cast<float>(height)));
    }

    const wchar_t* family_name = L"Microsoft YaHei UI";
    if (!Gdiplus::FontFamily(family_name).IsAvailable()) {
      family_name = L"Segoe UI";
    }
    Gdiplus::FontFamily family(family_name);
    const float name_size = std::max(11.0f, font_dip_ * 0.30f) * scale;
    Gdiplus::Font name_font(&family, name_size, Gdiplus::FontStyleRegular,
                            Gdiplus::UnitPixel);
    Gdiplus::Font bpm_font(&family, font_dip_ * scale, Gdiplus::FontStyleBold,
                           Gdiplus::UnitPixel);
    Gdiplus::Font button_font(&family, 10.0f * scale, Gdiplus::FontStyleRegular,
                              Gdiplus::UnitPixel);
    Gdiplus::SolidBrush name_brush(Gdiplus::Color(235, 255, 255, 255));
    Gdiplus::SolidBrush dim_brush(Gdiplus::Color(150, 255, 255, 255));
    Gdiplus::SolidBrush bpm_brush(Gdiplus::Color(255, 255, 82, 82));
    Gdiplus::Pen line_pen(Gdiplus::Color(255, 255, 82, 82), 1.6f * scale);
    Gdiplus::Pen gap_pen(Gdiplus::Color(110, 255, 82, 82), 1.2f * scale);
    gap_pen.SetDashStyle(Gdiplus::DashStyleDash);

    for (size_t index = 0; index < rows_.size(); ++index) {
      const OverlayRow& row = rows_[index];
      const float y = top + static_cast<float>(index) * row_height;
      const float name_x = left + kGutterDip * scale;
      const float bpm_x = name_x + kNameWidthDip * scale + kGapDip * scale;
      const float chart_x = bpm_x + bpm_width + kGapDip * scale;

      // 浅色桌面上白字会糊：先画一层偏移 1px 的深色影子再画正文。
      Gdiplus::SolidBrush shadow(Gdiplus::Color(130, 0, 0, 0));
      g.DrawString(row.name.c_str(), -1, &name_font,
                   Gdiplus::RectF(name_x + 1.0f, y + 1.0f, kNameWidthDip * scale,
                                  row_height),
                   nullptr, &shadow);
      g.DrawString(row.name.c_str(), -1, &name_font,
                   Gdiplus::RectF(name_x, y, kNameWidthDip * scale, row_height),
                   nullptr, &name_brush);
      Gdiplus::StringFormat right;
      right.SetAlignment(Gdiplus::StringAlignmentFar);
      g.DrawString(row.bpm.c_str(), -1, &bpm_font,
                   Gdiplus::RectF(bpm_x + 1.0f, y + 1.0f, bpm_width, row_height),
                   &right, &shadow);
      g.DrawString(row.bpm.c_str(), -1, &bpm_font,
                   Gdiplus::RectF(bpm_x, y, bpm_width, row_height), &right,
                   row.online ? &bpm_brush : &dim_brush);

      // 迷你折线：ys 由 Dart 归一化（0=顶部，1=底部），gaps 标记断点。
      if (row.ys.size() >= 2) {
        const float chart_w = kChartWidthDip * scale;
        const float chart_h = row_height * 0.62f;
        const float chart_top = y + (row_height - chart_h) * 0.5f;
        const float last = static_cast<float>(row.ys.size() - 1);
        for (size_t p = 1; p < row.ys.size(); ++p) {
          const bool gap = p < row.gaps.size() && row.gaps[p] != 0;
          const float x0 = chart_x + chart_w * static_cast<float>(p - 1) / last;
          const float y0 = chart_top + chart_h * row.ys[p - 1];
          const float x1 = chart_x + chart_w * static_cast<float>(p) / last;
          const float y1 = chart_top + chart_h * row.ys[p];
          g.DrawLine(gap ? &gap_pen : &line_pen, x0, y0, x1, y1);
        }
      }
    }

    // 右侧「断开」小图标（就是半径 9 的圈 + 一撇，24 DIP 以内）。
    {
      const float button_w = kButtonDip * scale;
      const float bx = static_cast<float>(width) - kPaddingDip * scale - button_w;
      const float by = top;
      Gdiplus::Pen ring(Gdiplus::Color(220, 255, 255, 255), 1.4f * scale);
      g.DrawEllipse(&ring, Gdiplus::RectF(bx, by, button_w, row_height * 0.9f));
    }
  }

  POINT dst{rect.left, rect.top};
  SIZE size{width, height};
  POINT src{0, 0};
  BLENDFUNCTION blend{};
  blend.BlendOp = AC_SRC_OVER;
  blend.SourceConstantAlpha = 255;
  blend.AlphaFormat = AC_SRC_ALPHA;
  const BOOL updated = ::UpdateLayeredWindow(hwnd_, screen, &dst, &size, memory,
                                             &src, 0, &blend, ULW_ALPHA);
  Log(updated ? "overlay: ulw ok" : "overlay: ulw failed");

  ::SelectObject(memory, old);
  ::DeleteObject(bitmap);
  ::DeleteDC(memory);
  ::ReleaseDC(nullptr, screen);
}

LRESULT CALLBACK OverlayWindow::WndProc(HWND hwnd, UINT message, WPARAM wparam,
                                        LPARAM lparam) noexcept {
  if (message == WM_NCCREATE) {
    auto* create = reinterpret_cast<CREATESTRUCT*>(lparam);
    ::SetWindowLongPtr(hwnd, GWLP_USERDATA,
                       reinterpret_cast<LONG_PTR>(create->lpCreateParams));
    return TRUE;
  }
  auto* that = reinterpret_cast<OverlayWindow*>(
      ::GetWindowLongPtr(hwnd, GWLP_USERDATA));
  if (that != nullptr && that->hwnd_ != nullptr) {
    return that->Handle(message, wparam, lparam);
  }
  return ::DefWindowProc(hwnd, message, wparam, lparam);
}

LRESULT OverlayWindow::Handle(UINT message, WPARAM wparam, LPARAM lparam) noexcept {
  switch (message) {
    case WM_NCHITTEST: {
      RECT rect{};
      ::GetWindowRect(hwnd_, &rect);
      const float scale = static_cast<float>(::GetDpiForWindow(hwnd_)) / 96.0f;
      const LONG x = GET_X_LPARAM(lparam) - rect.left;
      const LONG y = GET_Y_LPARAM(lparam) - rect.top;
      if (x < 0 || y < 0 || x >= rect.right - rect.left || y >= rect.bottom - rect.top) {
        return HTNOWHERE;
      }
      // 左侧 16 DIP 才是拖动区；其余交给窗口自己（按钮能点）。
      if (x < static_cast<LONG>(kGutterDip * scale)) return HTCAPTION;
      return HTCLIENT;
    }
    case WM_LBUTTONUP: {
      RECT rect{};
      ::GetWindowRect(hwnd_, &rect);
      const float scale = static_cast<float>(::GetDpiForWindow(hwnd_)) / 96.0f;
      const LONG x = GET_X_LPARAM(lparam);
      const LONG y = GET_Y_LPARAM(lparam);
      const LONG button_left =
          rect.right - rect.left -
          static_cast<LONG>((kPaddingDip + kButtonDip) * scale);
      const LONG row_bottom =
          static_cast<LONG>((kVerticalPaddingDip + std::max(22.0f, font_dip_ * 1.4f)) * scale);
      if (x >= button_left && y >= 0 && y <= row_bottom) {
        Log("overlay: disconnect clicked");
        if (notify_ != nullptr) {
          ::PostMessage(notify_, kOverlayDisconnectMessage, 0, 0);
        }
      }
      return 0;
    }
    default:
      break;
  }
  return ::DefWindowProc(hwnd_, message, wparam, lparam);
}

}  // namespace hrs
