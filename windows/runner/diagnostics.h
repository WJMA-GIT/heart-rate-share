// 启动/崩溃诊断：一个文件、一处路径，main.cpp 与 flutter_window.cpp 共用。
// 路径：%LOCALAPPDATA%\heartrate\logs\startup.log（崩溃另有 crash.log）。
#pragma once

#include <windows.h>

#include <cstdio>
#include <string>

namespace hrs {

inline std::wstring LogDir() {
  wchar_t buffer[MAX_PATH] = {0};
  const DWORD len = ::GetEnvironmentVariableW(L"LOCALAPPDATA", buffer, MAX_PATH);
  std::wstring dir =
      (len > 0 && len < MAX_PATH) ? std::wstring(buffer, len) : std::wstring(L".");
  const std::wstring root = dir + L"\\heartrate";
  dir = root + L"\\logs";
  ::CreateDirectoryW(root.c_str(), nullptr);
  ::CreateDirectoryW(dir.c_str(), nullptr);
  return dir;
}

// 单文件上限 2 MB，保留 3 份：日志刷屏时不能把磁盘吃掉（1.8 MB/分钟那种）。
constexpr unsigned long long kMaxLogBytes = 2ull * 1024 * 1024;
constexpr int kKeepFiles = 3;

inline void RotateIfNeeded(const std::wstring& path) {
  WIN32_FILE_ATTRIBUTE_DATA attr{};
  if (!::GetFileAttributesExW(path.c_str(), GetFileExInfoStandard, &attr)) return;
  const unsigned long long size =
      (static_cast<unsigned long long>(attr.nFileSizeHigh) << 32) | attr.nFileSizeLow;
  if (size < kMaxLogBytes) return;
  for (int index = kKeepFiles - 1; index >= 1; --index) {
    const std::wstring from = path + L"." + std::to_wstring(index);
    const std::wstring to = path + L"." + std::to_wstring(index + 1);
    ::MoveFileExW(from.c_str(), to.c_str(), MOVEFILE_REPLACE_EXISTING);
  }
  ::MoveFileExW(path.c_str(), (path + L".1").c_str(), MOVEFILE_REPLACE_EXISTING);
}

// UTF-8 → 宽字符：%hs 会按当前 ANSI 代码页转换，中文路径就成了 "é»è®¤"，
// 所以这里显式 MultiByteToWideChar(CP_UTF8) 再用 %ls 输出。
inline std::wstring WidenUtf8(const std::string& utf8) {
  if (utf8.empty()) return {};
  const int size = ::MultiByteToWideChar(CP_UTF8, 0, utf8.c_str(),
                                        static_cast<int>(utf8.size()), nullptr, 0);
  if (size <= 0) return L"";
  std::wstring out(static_cast<size_t>(size), L'\0');
  ::MultiByteToWideChar(CP_UTF8, 0, utf8.c_str(), static_cast<int>(utf8.size()), out.data(),
                        size);
  return out;
}

inline void Log(const char* stage, const std::string& detail = {}) {
  const std::wstring path = LogDir() + L"\\startup.log";
  RotateIfNeeded(path);
  FILE* fp = nullptr;
  if (_wfopen_s(&fp, path.c_str(), L"a, ccs=UTF-8") != 0 || fp == nullptr) return;
  SYSTEMTIME st;
  ::GetLocalTime(&st);
  const std::wstring wide_stage = WidenUtf8(stage);
  const std::wstring wide_detail = WidenUtf8(detail);
  fwprintf(fp, L"[%04d-%02d-%02d %02d:%02d:%02d] %ls %ls\n", st.wYear, st.wMonth, st.wDay,
           st.wHour, st.wMinute, st.wSecond, wide_stage.c_str(), wide_detail.c_str());
  fclose(fp);
}

}  // namespace hrs
