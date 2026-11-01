#include "flutter_window.h"

#include <optional>
#include <string>
#include <utility>
#include <vector>

#include "diagnostics.h"

#include "flutter/generated_plugin_registrant.h"

FlutterWindow::FlutterWindow(const flutter::DartProject& project)
    : project_(project) {}

FlutterWindow::~FlutterWindow() {}

bool FlutterWindow::OnCreate() {
  if (!Win32Window::OnCreate()) {
    return false;
  }

  RECT frame = GetClientArea();

  flutter_controller_ = std::make_unique<flutter::FlutterViewController>(
      frame.right - frame.left, frame.bottom - frame.top, project_);
  if (!flutter_controller_->engine() || !flutter_controller_->view()) {
    return false;
  }
  RegisterPlugins(flutter_controller_->engine());
  SetChildContent(flutter_controller_->view()->GetNativeWindow());

  // 标准窗口下 Flutter 视图必须正好等于客户区；不等就是"UI 在窗口里移动"的根源。
  {
    RECT child{};
    ::GetWindowRect(flutter_controller_->view()->GetNativeWindow(), &child);
    RECT client = GetClientArea();
    const long cw = client.right - client.left;
    const long ch = client.bottom - client.top;
    const long vw = child.right - child.left;
    const long vh = child.bottom - child.top;
    if (cw == vw && ch == vh) {
      hrs::Log("view==client OK", std::to_string(cw) + "x" + std::to_string(ch));
    } else {
      hrs::Log("view/client MISMATCH",
               "client=" + std::to_string(cw) + "x" + std::to_string(ch) +
                   " view=" + std::to_string(vw) + "x" + std::to_string(vh));
    }
  }

  // 悬浮窗在这里创建（不是 main.cpp 注入）：成员对象，生命周期和本窗口一致，
  // 通道回调捕获 this 拿到的就是同一个实例。
  if (overlay_.Create(GetHandle())) {
    hrs::Log("overlay: ready");
  } else {
    hrs::Log("overlay: create failed, 悬浮窗不可用（主界面不受影响）");
  }

  // Dart → 原生：setOverlay(rows/font) / showOverlay(bool)。
  // 原生 → Dart：overlayDisconnect（悬浮窗上点了断开）。
  channel_ = std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
      flutter_controller_->engine()->messenger(), "hrs/win",
      &flutter::StandardMethodCodec::GetInstance());
  channel_->SetMethodCallHandler(
      [this](const flutter::MethodCall<flutter::EncodableValue>& call,
             std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result) {
        hrs::Log("channel", call.method_name() +
                           std::string(" overlay=") +
                           (overlay_.handle() != nullptr ? "ok" : "null"));
        if (call.method_name() == "showOverlay") {
          // 参数缺失时按"要显示"处理：宁可多显示一次，也不要静默走 Hide 分支。
          const auto* flag = std::get_if<bool>(call.arguments());
          const bool want_show = (flag == nullptr) ? true : *flag;
          if (want_show) {
            overlay_.Show();
          } else {
            overlay_.Hide();
          }
          result->Success();
          return;
        }
        if (call.method_name() == "setOverlay") {
          const auto* args = std::get_if<flutter::EncodableMap>(call.arguments());
          if (args == nullptr) {
            result->Success();
            return;
          }
          float font = 48.0f;
          const auto font_it = args->find(flutter::EncodableValue("font"));
          if (font_it != args->end()) {
            if (const auto* value = std::get_if<double>(&font_it->second)) {
              font = static_cast<float>(*value);
            }
          }
          std::vector<hrs::OverlayRow> rows;
          const auto rows_it = args->find(flutter::EncodableValue("rows"));
          if (rows_it != args->end()) {
            if (const auto* list = std::get_if<flutter::EncodableList>(&rows_it->second)) {
              for (const auto& item : *list) {
                const auto* map = std::get_if<flutter::EncodableMap>(&item);
                if (map == nullptr) continue;
                hrs::OverlayRow row;
                const auto name = map->find(flutter::EncodableValue("name"));
                if (name != map->end()) {
                  if (const auto* text = std::get_if<std::string>(&name->second)) {
                    row.name.assign(text->begin(), text->end());
                  }
                }
                const auto bpm = map->find(flutter::EncodableValue("bpm"));
                if (bpm != map->end()) {
                  if (const auto* text = std::get_if<std::string>(&bpm->second)) {
                    row.bpm.assign(text->begin(), text->end());
                  }
                }
                const auto online = map->find(flutter::EncodableValue("online"));
                if (online != map->end()) {
                  if (const auto* flag = std::get_if<bool>(&online->second)) {
                    row.online = *flag;
                  }
                }
                const auto ys = map->find(flutter::EncodableValue("ys"));
                if (ys != map->end()) {
                  if (const auto* ys_list =
                          std::get_if<flutter::EncodableList>(&ys->second)) {
                    row.ys.reserve(ys_list->size());
                    for (const auto& value : *ys_list) {
                      if (const auto* d = std::get_if<double>(&value)) {
                        row.ys.push_back(static_cast<float>(*d));
                      }
                    }
                  }
                }
                const auto gaps = map->find(flutter::EncodableValue("gaps"));
                if (gaps != map->end()) {
                  if (const auto* gap_list =
                          std::get_if<flutter::EncodableList>(&gaps->second)) {
                    row.gaps.reserve(gap_list->size());
                    for (const auto& value : *gap_list) {
                      if (const auto* i = std::get_if<int32_t>(&value)) {
                        row.gaps.push_back(*i);
                      }
                    }
                  }
                }
                rows.push_back(std::move(row));
              }
            }
          }
          overlay_.SetRows(std::move(rows), font);
          result->Success();
          return;
        }
        result->NotImplemented();
      });

  flutter_controller_->engine()->SetNextFrameCallback([&]() {
    hrs::Log("stage: first frame");
    this->Show();
    hrs::Log("stage: window shown");
  });

  flutter_controller_->ForceRedraw();
  return true;
}

void FlutterWindow::OnDestroy() {
  channel_.reset();
  if (flutter_controller_) {
    flutter_controller_ = nullptr;
  }

  Win32Window::OnDestroy();
}

LRESULT
FlutterWindow::MessageHandler(HWND hwnd, UINT const message,
                              WPARAM const wparam,
                              LPARAM const lparam) noexcept {
  // 悬浮窗上点了「断开」：转给 Dart，由业务层断开连接。
  if (message == hrs::kOverlayDisconnectMessage) {
    if (channel_ != nullptr) {
      channel_->InvokeMethod("overlayDisconnect", nullptr);
    }
    return 0;
  }

  // Give Flutter, including plugins, an opportunity to handle window messages.
  if (flutter_controller_) {
    std::optional<LRESULT> result =
        flutter_controller_->HandleTopLevelWindowProc(hwnd, message, wparam,
                                                      lparam);
    if (result) {
      return *result;
    }
  }

  switch (message) {
    case WM_FONTCHANGE:
      flutter_controller_->engine()->ReloadSystemFonts();
      break;
  }

  return Win32Window::MessageHandler(hwnd, message, wparam, lparam);
}
