// 单文件启动器：heartrate.exe + 全部 DLL + data/ 以 zip 形式追加在本 exe 末尾。
// 双击 → 静默释放到 %LOCALAPPDATA%\heartrate\app\p<size>\ → 起主程序 → 自身退出。
// 不弹解压窗口、不要管理员、不写注册表。
// 页脚（最后 32 字节）：magic[8] + payloadOffset(u64) + payloadSize(u64) + reserved(u64)
#include <windows.h>

#include <cstdint>
#include <cstring>
#include <string>
#include <vector>

namespace {

constexpr char kMagic[8] = {'H', 'R', 'S', 'L', 'D', '0', '0', '1'};

std::wstring Env(const wchar_t* name) {
  wchar_t buffer[MAX_PATH] = {0};
  const DWORD len = ::GetEnvironmentVariableW(name, buffer, MAX_PATH);
  return len > 0 ? std::wstring(buffer, len) : std::wstring();
}

bool Exists(const std::wstring& path) {
  return ::GetFileAttributesW(path.c_str()) != INVALID_FILE_ATTRIBUTES;
}

void Fail(const wchar_t* text) { ::MessageBoxW(nullptr, text, L"共享心率", MB_ICONERROR | MB_OK); }

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
  ::WaitForSingleObject(pi.hProcess, 120 * 1000);
  DWORD code = 1;
  ::GetExitCodeProcess(pi.hProcess, &code);
  ::CloseHandle(pi.hThread);
  ::CloseHandle(pi.hProcess);
  return code == 0;
}

}  // namespace

int WINAPI wWinMain(HINSTANCE, HINSTANCE, LPWSTR, int) {
  wchar_t self[MAX_PATH] = {0};
  ::GetModuleFileNameW(nullptr, self, MAX_PATH);

  HANDLE file = ::CreateFileW(self, GENERIC_READ, FILE_SHARE_READ, nullptr, OPEN_EXISTING,
                              FILE_ATTRIBUTE_NORMAL, nullptr);
  if (file == INVALID_HANDLE_VALUE) {
    Fail(L"无法读取自身文件。");
    return 1;
  }
  LARGE_INTEGER size{};
  ::GetFileSizeEx(file, &size);
  if (size.QuadPart < 32) {
    ::CloseHandle(file);
    Fail(L"文件不完整（没有载荷）。请重新下载。");
    return 1;
  }

  unsigned char footer[32] = {0};
  LARGE_INTEGER at{};
  at.QuadPart = size.QuadPart - 32;
  ::SetFilePointerEx(file, at, nullptr, FILE_BEGIN);
  DWORD read = 0;
  ::ReadFile(file, footer, 32, &read, nullptr);
  if (read != 32 || memcmp(footer, kMagic, 8) != 0) {
    ::CloseHandle(file);
    Fail(L"文件不完整（页脚校验失败）。请重新下载。");
    return 1;
  }
  uint64_t offset = 0;
  uint64_t payload = 0;
  memcpy(&offset, footer + 8, 8);
  memcpy(&payload, footer + 16, 8);
  if (offset + payload > static_cast<uint64_t>(size.QuadPart)) {
    ::CloseHandle(file);
    Fail(L"文件已损坏（载荷越界）。请重新下载。");
    return 1;
  }

  const std::wstring local = Env(L"LOCALAPPDATA");
  if (local.empty()) {
    ::CloseHandle(file);
    Fail(L"找不到 %LOCALAPPDATA%。");
    return 1;
  }
  const std::wstring dest = local + L"\\heartrate\\app\\p" + std::to_wstring(payload);
  const std::wstring exe = dest + L"\\heartrate.exe";
  const std::wstring marker = dest + L"\\.ready";

  if (Exists(exe) && Exists(marker)) {
    ::CloseHandle(file);
  } else {
    ::CreateDirectoryW((local + L"\\heartrate").c_str(), nullptr);
    ::CreateDirectoryW((local + L"\\heartrate\\app").c_str(), nullptr);
    ::CreateDirectoryW(dest.c_str(), nullptr);

    const std::wstring zip = local + L"\\heartrate\\payload.zip";
    HANDLE out = ::CreateFileW(zip.c_str(), GENERIC_WRITE, 0, nullptr, CREATE_ALWAYS,
                               FILE_ATTRIBUTE_NORMAL, nullptr);
    if (out == INVALID_HANDLE_VALUE) {
      ::CloseHandle(file);
      Fail(L"无法写入临时文件（%LOCALAPPDATA% 不可写？）。");
      return 1;
    }
    at.QuadPart = static_cast<LONGLONG>(offset);
    ::SetFilePointerEx(file, at, nullptr, FILE_BEGIN);
    std::vector<char> chunk(64 * 1024);
    uint64_t left = payload;
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
      Fail(L"读取载荷失败，文件可能损坏。");
      return 1;
    }

    // 用系统自带的 tar.exe（Win10 1803+ 的 bsdtar 支持 zip）静默解压。
    const std::wstring tar_cmd = L"tar.exe -xf \"" + zip + L"\" -C \"" + dest + L"\"";
    if (!RunAndWait(tar_cmd)) {
      Fail(L"解压失败：系统缺少 tar.exe（需要 Windows 10 1803 及以上）。");
      return 1;
    }
    ::DeleteFileW(zip.c_str());
    HANDLE m = ::CreateFileW(marker.c_str(), GENERIC_WRITE, 0, nullptr, CREATE_ALWAYS,
                             FILE_ATTRIBUTE_NORMAL, nullptr);
    if (m != INVALID_HANDLE_VALUE) ::CloseHandle(m);
  }

  STARTUPINFOW si{};
  si.cb = sizeof(si);
  PROCESS_INFORMATION pi{};
  std::wstring cmd = L"\"" + exe + L"\"";
  std::vector<wchar_t> buffer(cmd.begin(), cmd.end());
  buffer.push_back(L'\0');
  if (!::CreateProcessW(exe.c_str(), buffer.data(), nullptr, nullptr, FALSE, 0, nullptr,
                        dest.c_str(), &si, &pi)) {
    Fail(L"启动主程序失败。请把 %LOCALAPPDATA%\\heartrate\\logs\\startup.log 发回。");
    return 1;
  }
  ::CloseHandle(pi.hThread);
  ::CloseHandle(pi.hProcess);
  return 0;
}
