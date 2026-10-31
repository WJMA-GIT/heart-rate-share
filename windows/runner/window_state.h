// 窗口几何记忆：%LOCALAPPDATA%\heartrate\window.state
// 一行 "x y w h maximized"（物理像素，和 Windows 自己记窗口位置用同一套坐标）。
#pragma once

#include <windows.h>

namespace hrs {

// 读回上次退出时的窗口矩形。以下情况返回 false（调用方回落到主屏居中）：
// 首次运行 / 文件坏了 / 记录的矩形已经不在任何显示器工作区里（拔掉了外接屏）。
bool LoadWindowRect(RECT* rect, bool* maximized);

// 退出时落盘。最大化时记的是还原后的正常矩形，不是铺满屏幕的那一份。
void SaveWindowRect(HWND window);

}  // namespace hrs
