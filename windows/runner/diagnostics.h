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

inline void Log(const char* stage, const std::string& detail = {}) {
  const std::wstring path = LogDir() + L"\\startup.log";
  FILE* fp = nullptr;
  if (_wfopen_s(&fp, path.c_str(), L"a, ccs=UTF-8") != 0 || fp == nullptr) return;
  SYSTEMTIME st;
  ::GetLocalTime(&st);
  fwprintf(fp, L"[%04d-%02d-%02d %02d:%02d:%02d] %hs %hs\n", st.wYear, st.wMonth, st.wDay,
           st.wHour, st.wMinute, st.wSecond, stage, detail.c_str());
  fclose(fp);
}

}  // namespace hrs
