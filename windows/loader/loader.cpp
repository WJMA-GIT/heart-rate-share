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

// 只保留当前版本目录，避免旧版本无限堆积（每版约 45 MB）。
void CleanOlderVersions(const std::wstring& appRoot, const std::wstring& keep) {
  WIN32_FIND_DATAW data{};
  HANDLE find = ::FindFirstFileW(LongPath(appRoot + L"\\*").c_str(), &data);
  if (find == INVALID_HANDLE_VALUE) return;
  do {
    if (data.dwFileAttributes & FILE_ATTRIBUTE_DIRECTORY) {
      const std::wstring name = data.cFileName;
      if (name == L"." || name == L".." || name == keep) continue;
      // 只删我们自己的版本目录（形如 p<数字> 或 <数字>.<数字>.<数字>*）
      if (name.empty() || (name[0] != L'p' && (name[0] < L'0' || name[0] > L'9'))) continue;
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
    if (n > 0) {
      wideVersion.resize(n - 1);
      ::MultiByteToWideChar(CP_UTF8, 0, version, -1, wideVersion.data(), n);
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
  const std::wstring dest = appRoot + L"\\" + wideVersion;
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

  CleanOlderVersions(appRoot, wideVersion);

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
