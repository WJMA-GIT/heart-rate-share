// 单文件启动器（v2 页脚）。
// 布局：[loader.exe][payload.zip][footer 128B]
// footer: magic" HRSLD002"(8) + formatVersion(u32) + reserved(u32) +
//         payloadOffset(u64) + payloadLength(u64) + sha256(payload)[32] + appVersion[32](UTF-8)
//
// 流程：校验 magic/版本/长度/SHA-256 → （命名互斥量）解到 app\<ver>.tmp → 原子 rename 成 app\<ver>
//       → CreateProcessW 起主程序 → 自身退出。热启动命中缓存直接拉起。
// 不弹解压窗口、不要管理员、不写注册表。
#include <windows.h>
#include <bcrypt.h>

#include <cstdint>
#include <cstdio>
#include <cstring>
#include <string>
#include <vector>

#pragma comment(lib, "bcrypt.lib")

namespace {

constexpr char kMagic[8] = {'H', 'R', 'S', 'L', 'D', '0', '0', '2'};
constexpr uint32_t kFormatVersion = 2;
constexpr size_t kFooterSize = 128;

struct Footer {
  char magic[8];
  uint32_t formatVersion;
  uint32_t reserved;
  uint64_t payloadOffset;
  uint64_t payloadLength;
  unsigned char sha256[32];
  char appVersion[32];
};

std::wstring Env(const wchar_t* name) {
  wchar_t buffer[MAX_PATH] = {0};
  const DWORD len = ::GetEnvironmentVariableW(name, buffer, MAX_PATH);
  return len > 0 ? std::wstring(buffer, len) : std::wstring();
}

std::wstring LongPath(const std::wstring& path) {
  // >240 字符时加 \\?\ 前缀（中文/空格本身不需要，但长路径需要）。
  if (path.size() < 240 || path.rfind(L"\\\\?\\", 0) == 0) return path;
  return L"\\\\?\\" + path;
}

// 和 runner 写同一份 startup.log（UTF-8），用户回传一个文件就能看出跑的是哪次构建。
void AppendLog(const std::wstring& line) {
  const std::wstring local = Env(L"LOCALAPPDATA");
  if (local.empty()) return;
  const std::wstring dir = local + L"\\heartrate\\logs";
  ::CreateDirectoryW((local + L"\\heartrate").c_str(), nullptr);
  ::CreateDirectoryW(dir.c_str(), nullptr);
  const std::wstring path = dir + L"\\startup.log";
  HANDLE file = ::CreateFileW(LongPath(path).c_str(), FILE_APPEND_DATA,
                              FILE_SHARE_READ | FILE_SHARE_WRITE, nullptr, OPEN_ALWAYS,
                              FILE_ATTRIBUTE_NORMAL, nullptr);
  if (file == INVALID_HANDLE_VALUE) return;
  SYSTEMTIME st{};
  ::GetLocalTime(&st);
  wchar_t stamp[32] = {0};
  ::_snwprintf_s(stamp, 32, _TRUNCATE, L"[%04d-%02d-%02d %02d:%02d:%02d] ", st.wYear,
                 st.wMonth, st.wDay, st.wHour, st.wMinute, st.wSecond);
  const std::wstring text = std::wstring(stamp) + L"loader: " + line + L"\r\n";
  const int bytes =
      ::WideCharToMultiByte(CP_UTF8, 0, text.c_str(), -1, nullptr, 0, nullptr, nullptr);
  if (bytes > 1) {
    std::vector<char> buffer(static_cast<size_t>(bytes));
    ::WideCharToMultiByte(CP_UTF8, 0, text.c_str(), -1, buffer.data(), bytes, nullptr,
                          nullptr);
    DWORD written = 0;
    ::WriteFile(file, buffer.data(), static_cast<DWORD>(bytes - 1), &written, nullptr);
  }
  ::CloseHandle(file);
}

bool Exists(const std::wstring& path) {
  return ::GetFileAttributesW(LongPath(path).c_str()) != INVALID_FILE_ATTRIBUTES;
}

void Fail(const std::wstring& what, const std::wstring& detail, const std::wstring& path) {
  std::wstring text = L"共享心率启动失败\n";
  text += what + L"\n";
  if (!detail.empty()) text += detail + L"\n";
  text += L"路径：" + path;
  ::MessageBoxW(nullptr, text.c_str(), L"共享心率", MB_ICONERROR | MB_OK);
}

bool Sha256File(HANDLE file, uint64_t offset, uint64_t length, unsigned char out[32]) {
  BCRYPT_ALG_HANDLE alg = nullptr;
  if (::BCryptOpenAlgorithmProvider(&alg, BCRYPT_SHA256_ALGORITHM, nullptr, 0) < 0) return false;
  BCRYPT_HASH_HANDLE hash = nullptr;
  const bool created =
      ::BCryptCreateHash(alg, &hash, nullptr, 0, nullptr, 0, 0) >= 0;
  bool ok = created;
  if (ok) {
    LARGE_INTEGER at{};
    at.QuadPart = static_cast<LONGLONG>(offset);
    ok = ::SetFilePointerEx(file, at, nullptr, FILE_BEGIN) != 0;
    std::vector<unsigned char> buffer(64 * 1024);
    uint64_t left = length;
    while (ok && left > 0) {
      const DWORD want = static_cast<DWORD>(left < buffer.size() ? left : buffer.size());
      DWORD got = 0;
      ok = ::ReadFile(file, buffer.data(), want, &got, nullptr) != 0 && got > 0;
      if (!ok) break;
      ok = ::BCryptHashData(hash, buffer.data(), got, 0) >= 0;
      left -= got;
    }
    if (ok) ok = ::BCryptFinishHash(hash, out, 32, 0) >= 0;
  }
  if (hash) ::BCryptDestroyHash(hash);
  ::BCryptCloseAlgorithmProvider(alg, 0);
  return ok;
}

bool RunAndWait(const std::wstring& cmdline) {
  STARTUPINFOW si{};
  si.cb = sizeof(si);
  PROCESS_INFORMATION pi{};
  std::vector<wchar_t> buffer(cmdline.begin(), cmdline.end());
  buffer.push_back(L'\0');
  if (!::CreateProcessW(nullptr, buffer.data(), nullptr, nullptr, FALSE, CREATE_NO_WINDOW,
                        nullptr, nullptr, &si, &pi)) {
    return false;
  }
  ::WaitForSingleObject(pi.hProcess, 180 * 1000);
  DWORD code = 1;
  ::GetExitCodeProcess(pi.hProcess, &code);
  ::CloseHandle(pi.hThread);
  ::CloseHandle(pi.hProcess);
  return code == 0;
}

// 目录名是 payload sha256 的前 8 位（8 个小写 hex）。保留当前目录 + 最近用的一个，
// 旧的删掉——重新发版就天然换了目录，不会再跑旧文件。
void CleanOlderVersions(const std::wstring& appRoot, const std::wstring& keep) {
  WIN32_FIND_DATAW data{};
  HANDLE find = ::FindFirstFileW(LongPath(appRoot + L"\\*").c_str(), &data);
  if (find == INVALID_HANDLE_VALUE) return;
  std::wstring newestOther;
  ULARGE_INTEGER newestTime{};
  do {
    if (data.dwFileAttributes & FILE_ATTRIBUTE_DIRECTORY) {
      const std::wstring name = data.cFileName;
      if (name == L"." || name == L".." || name == keep) continue;
      if (name.size() != 8) continue;
      bool hex = true;
      for (wchar_t ch : name) {
        if (!((ch >= L'0' && ch <= L'9') || (ch >= L'a' && ch <= L'f'))) {
          hex = false;
          break;
        }
      }
      if (!hex) continue;
      ULARGE_INTEGER stamp{};
      stamp.LowPart = data.ftLastWriteTime.dwLowDateTime;
      stamp.HighPart = data.ftLastWriteTime.dwHighDateTime;
      if (newestOther.empty() || stamp.QuadPart > newestTime.QuadPart) {
        newestOther = name;
        newestTime = stamp;
      }
    }
  } while (::FindNextFileW(find, &data));
  ::FindClose(find);

  // 只保留"最近的一个旧目录"，其余全删。
  find = ::FindFirstFileW(LongPath(appRoot + L"\\*").c_str(), &data);
  if (find == INVALID_HANDLE_VALUE) return;
  do {
    if (data.dwFileAttributes & FILE_ATTRIBUTE_DIRECTORY) {
      const std::wstring name = data.cFileName;
      if (name == L"." || name == L".." || name == keep || name == newestOther) continue;
      if (name.size() != 8) continue;
      std::wstring cmd = L"cmd.exe /c rmdir /s /q \"" + appRoot + L"\\" + name + L"\"";
      RunAndWait(cmd);
    }
  } while (::FindNextFileW(find, &data));
  ::FindClose(find);
}

}  // namespace

int WINAPI wWinMain(HINSTANCE, HINSTANCE, LPWSTR, int) {
  wchar_t self[MAX_PATH * 2] = {0};
  ::GetModuleFileNameW(nullptr, self, static_cast<DWORD>(std::size(self)));
  const std::wstring selfPath(self);

  HANDLE file = ::CreateFileW(LongPath(selfPath).c_str(), GENERIC_READ, FILE_SHARE_READ, nullptr,
                              OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL, nullptr);
  if (file == INVALID_HANDLE_VALUE) {
    Fail(L"无法读取自身文件。", L"错误码：读取失败", selfPath);
    return 1;
  }
  LARGE_INTEGER size{};
  ::GetFileSizeEx(file, &size);
  if (size.QuadPart < static_cast<LONGLONG>(kFooterSize + 1024)) {
    Fail(L"文件不完整。", L"错误码：文件过小", selfPath);
    ::CloseHandle(file);
    return 1;
  }

  Footer footer{};
  LARGE_INTEGER at{};
  at.QuadPart = size.QuadPart - static_cast<LONGLONG>(kFooterSize);
  ::SetFilePointerEx(file, at, nullptr, FILE_BEGIN);
  DWORD read = 0;
  if (!::ReadFile(file, &footer, kFooterSize, &read, nullptr) || read != kFooterSize ||
      memcmp(footer.magic, kMagic, 8) != 0 || footer.formatVersion != kFormatVersion) {
    Fail(L"文件已损坏（页脚校验失败）。", L"错误码：footer_mismatch", selfPath);
    ::CloseHandle(file);
    return 1;
  }
  if (footer.payloadOffset + footer.payloadLength > static_cast<uint64_t>(size.QuadPart)) {
    Fail(L"文件已损坏（载荷越界）。", L"错误码：payload_out_of_range", selfPath);
    ::CloseHandle(file);
    return 1;
  }

  unsigned char digest[32] = {0};
  if (!Sha256File(file, footer.payloadOffset, footer.payloadLength, digest) ||
      memcmp(digest, footer.sha256, 32) != 0) {
    Fail(L"文件已损坏（SHA-256 校验失败），请重新下载。", L"错误码：sha256_mismatch", selfPath);
    ::CloseHandle(file);
    return 1;
  }

  char version[33] = {0};
  memcpy(version, footer.appVersion, 32);
  std::wstring wideVersion;
  {
    const int n = ::MultiByteToWideChar(CP_UTF8, 0, version, -1, nullptr, 0);
    if (n > 1) {
      wideVersion.resize(static_cast<size_t>(n));
      ::MultiByteToWideChar(CP_UTF8, 0, version, -1, &wideVersion[0], n);
      wideVersion.resize(static_cast<size_t>(n - 1));  // 去掉结尾 NUL
    }
  }
  if (wideVersion.empty()) wideVersion = L"unknown";

  const std::wstring local = Env(L"LOCALAPPDATA");
  if (local.empty()) {
    Fail(L"找不到 %LOCALAPPDATA%。", L"错误码：no_localappdata", selfPath);
    ::CloseHandle(file);
    return 1;
  }
  const std::wstring appRoot = local + L"\\heartrate\\app";

  // 解压目录**按 payload 的 sha256 前 8 位**命名，不按版本名。
  // 版本名不变只递增构建号时（1.0.15 反复重发），按版本名会命中旧目录，
  // 用户就永远跑着上一版（1.0.15 新 UI 没生效就是这么来的）。
  std::wstring shaHex;
  for (int i = 0; i < 32; ++i) {
    static const wchar_t* digits = L"0123456789abcdef";
    shaHex.push_back(digits[footer.sha256[i] >> 4]);
    shaHex.push_back(digits[footer.sha256[i] & 0x0F]);
  }
  const std::wstring key = shaHex.substr(0, 8);
  const std::wstring dest = appRoot + L"\\" + key;
  const std::wstring destExe = dest + L"\\heartrate.exe";

  HANDLE mutex = ::CreateMutexW(nullptr, FALSE, L"Local\\HeartRateShareLoader");
  if (mutex != nullptr) ::WaitForSingleObject(mutex, 60 * 1000);

  if (!Exists(destExe)) {
    const std::wstring tmp = dest + L".tmp";
    RunAndWait(L"cmd.exe /c rmdir /s /q \"" + tmp + L"\"");
    ::CreateDirectoryW(LongPath(local + L"\\heartrate").c_str(), nullptr);
    ::CreateDirectoryW(LongPath(appRoot).c_str(), nullptr);
    ::CreateDirectoryW(LongPath(tmp).c_str(), nullptr);

    const std::wstring zip = local + L"\\heartrate\\payload.zip";
    HANDLE out = ::CreateFileW(LongPath(zip).c_str(), GENERIC_WRITE, 0, nullptr, CREATE_ALWAYS,
                               FILE_ATTRIBUTE_NORMAL, nullptr);
    if (out == INVALID_HANDLE_VALUE) {
      Fail(L"无法写入临时文件。", L"错误码：payload_write_failed", zip);
      if (mutex) ::ReleaseMutex(mutex);
      ::CloseHandle(file);
      return 1;
    }
    at.QuadPart = static_cast<LONGLONG>(footer.payloadOffset);
    ::SetFilePointerEx(file, at, nullptr, FILE_BEGIN);
    std::vector<char> chunk(64 * 1024);
    uint64_t left = footer.payloadLength;
    while (left > 0) {
      const DWORD want = static_cast<DWORD>(left < chunk.size() ? left : chunk.size());
      DWORD got = 0;
      if (!::ReadFile(file, chunk.data(), want, &got, nullptr) || got == 0) break;
      DWORD written = 0;
      ::WriteFile(out, chunk.data(), got, &written, nullptr);
      left -= got;
    }
    ::CloseHandle(out);
    ::CloseHandle(file);
    if (left != 0) {
      Fail(L"读取载荷失败。", L"错误码：payload_read_failed", zip);
      if (mutex) ::ReleaseMutex(mutex);
      return 1;
    }

    if (!RunAndWait(L"tar.exe -xf \"" + zip + L"\" -C \"" + tmp + L"\"")) {
      Fail(L"解压失败：系统缺少 tar.exe（需要 Windows 10 1803 及以上）。",
           L"错误码：extract_failed", tmp);
      if (mutex) ::ReleaseMutex(mutex);
      return 1;
    }
    ::DeleteFileW(LongPath(zip).c_str());

    if (Exists(dest)) RunAndWait(L"cmd.exe /c rmdir /s /q \"" + dest + L"\"");
    if (!::MoveFileExW(LongPath(tmp).c_str(), LongPath(dest).c_str(), 0)) {
      Fail(L"释放目录重命名失败（可能有另一个实例正在启动）。", L"错误码：rename_failed", tmp);
      if (mutex) ::ReleaseMutex(mutex);
      return 1;
    }
  } else {
    ::CloseHandle(file);
  }

  if (mutex) ::ReleaseMutex(mutex);
  if (mutex) ::CloseHandle(mutex);

  CleanOlderVersions(appRoot, key);
  AppendLog(L"payload sha256=" + shaHex);
  AppendLog(L"launch dir=" + dest);
  AppendLog(L"build=" + wideVersion + L"+" + key);

  STARTUPINFOW si{};
  si.cb = sizeof(si);
  PROCESS_INFORMATION pi{};
  std::wstring cmd = L"\"" + destExe + L"\"";
  std::vector<wchar_t> buffer(cmd.begin(), cmd.end());
  buffer.push_back(L'\0');
  if (!::CreateProcessW(LongPath(destExe).c_str(), buffer.data(), nullptr, nullptr, FALSE, 0,
                        nullptr, LongPath(dest).c_str(), &si, &pi)) {
    Fail(L"启动主程序失败。", L"错误码：create_process_failed", destExe);
    return 1;
  }
  ::CloseHandle(pi.hThread);
  ::CloseHandle(pi.hProcess);
  return 0;
}
