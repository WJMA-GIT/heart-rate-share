// 悬浮窗：独立原生窗口，C++ 自绘（GDI+ 抗锯齿 + 逐像素 alpha 分层）。
//
// 为什么不复用 Flutter：一个 Flutter engine 只能托一个 view，再开一个 engine 就是
// window_manager 那次 0xC000041D 的同类风险。这里只有「名称 | 心率 | 折线 | 断开」，
// 用 GDI+ 画既省一个 engine，字号和抗锯齿也完全可控。
#pragma once

#include <windows.h>

#include <string>
#include <vector>

namespace hrs {

// 悬浮窗点「断开」时发给主窗口的消息（主窗口再转给 Dart）。
constexpr UINT kOverlayDisconnectMessage = WM_APP + 21;

struct OverlayRow {
  std::wstring name;
  std::wstring bpm;   // "--" 表示没数据
  bool online = false;
  std::vector<float> ys;    // 归一化 0..1（Dart 侧算出）
  std::vector<int> gaps;    // 1 = 这个点前面断开
};

class OverlayWindow {
 public:
  OverlayWindow() = default;
  ~OverlayWindow();

  // |notify| 是主窗口句柄：点「断开」时往它发 kOverlayDisconnectMessage。
  bool Create(HWND notify);

  void SetRows(std::vector<OverlayRow> rows, float font_dip);
  void Show();
  void Hide();
  bool visible() const { return visible_; }
  HWND handle() const { return hwnd_; }

 private:
  static LRESULT CALLBACK WndProc(HWND hwnd, UINT message, WPARAM wparam,
                                  LPARAM lparam) noexcept;
  LRESULT Handle(UINT message, WPARAM wparam, LPARAM lparam) noexcept;

  void ResizeToContent();
  void Render();

  HWND hwnd_ = nullptr;
  HWND notify_ = nullptr;
  std::vector<OverlayRow> rows_;
  float font_dip_ = 48.0f;
  bool visible_ = false;
};

}  // namespace hrs
