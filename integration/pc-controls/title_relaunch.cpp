// Title relaunch between levels.
//
// Call of Duty 3 reboots itself at the end of a single-player level, as many
// 360 titles do to start the next map with clean memory. sub_82514710 hands
// 664 bytes of campaign state to XamLoaderSetLaunchData and calls
// XLaunchNewImage("default.xex") (sub_82343928); on start, sub_823FCCA8 reads
// the launch data back and turns it into "+devmap <next level>". The SDK's
// XamLoaderLaunchTitle only terminates the title, so the game closed on the
// saving screen at every level end.
//
// Here the relaunch is done by the host: the launch data goes to a file, a
// new cod3_pc.exe starts with the same command line plus that file, waits
// for this process to exit, and gives the data back to the game before it
// asks for it. The multiplayer executable (codmp_xenonf.xex) and exits to the
// dashboard still end the process.

#include <rex/cvar.h>
#include <rex/hook.h>
#include <rex/logging.h>

#ifndef WIN32_LEAN_AND_MEAN
#define WIN32_LEAN_AND_MEAN
#endif
#ifndef NOMINMAX
#define NOMINMAX
#endif
#include <windows.h>
#include <shellapi.h>

#include "title_relaunch.h"

#include <algorithm>
#include <array>
#include <atomic>
#include <chrono>
#include <thread>
#include <bit>
#include <cctype>
#include <cstdint>
#include <cstring>
#include <cwchar>
#include <filesystem>
#include <fstream>
#include <string>
#include <vector>

REXCVAR_DEFINE_BOOL(cod3_relaunch, true, "Game",
                    "When the game restarts itself for the next level (as the console did), start a new "
                    "instance instead of exiting");
REXCVAR_DEFINE_STRING(cod3_launch_data, "", "Game",
                      "Launch data left by the previous instance when the game restarted itself (set by the "
                      "relaunch, not by hand)");
REXCVAR_DEFINE_INT32(cod3_relaunch_wait, 0, "Game",
                     "Process id of the previous instance to wait for before starting (set by the relaunch)");

REX_EXTERN(__imp__sub_82343928);
REX_EXTERN(__imp__sub_823FCCA8);
REX_EXTERN(__imp__XamLoaderGetLaunchDataSize);
REX_EXTERN(__imp__XamLoaderGetLaunchData);
REX_EXTERN(__imp__XamLoaderSetLaunchData);

namespace {

constexpr uint32_t kMaxLaunchData = 0x1000;  // XAM allows 1 KB+; the game sends 664 bytes
constexpr const char* kLaunchDataFile = "cod3-launch-data.bin";
constexpr const char* kRelaunchMarker = "cod3-relaunch.txt";

// ---------------------------------------------------------------- start up

// "--name=value" from this process's own command line, before the SDK has
// parsed it (static initialisation).
std::wstring RawArgument(const wchar_t* name) {
  int count = 0;
  wchar_t** argv = CommandLineToArgvW(GetCommandLineW(), &count);
  if (!argv) return {};
  const std::wstring prefix = std::wstring(L"--") + name + L"=";
  std::wstring value;
  for (int i = 1; i < count; ++i) {
    if (std::wcsncmp(argv[i], prefix.c_str(), prefix.size()) == 0) value = argv[i] + prefix.size();
  }
  LocalFree(argv);
  return value;
}

// Seamless hand-over: the previous instance keeps its window on screen until
// this one runs and shows frames, then ends. Both may run for a moment; the
// files they share (log, shader storage) are opened for shared appending, and
// the saves were written before the game asked for the relaunch.
std::wstring ReadyEventName(unsigned long previous_pid) {
  return L"Local\\cod3-relaunch-ready-" + std::to_wstring(previous_pid);
}

unsigned long PreviousInstance() {
  static const unsigned long pid = [] {
    const std::wstring text = RawArgument(L"cod3_relaunch_wait");
    return text.empty() ? 0ul : std::wcstoul(text.c_str(), nullptr, 10);
  }();
  return pid;
}

// ------------------------------------------------------------ guest helpers

uint32_t LoadBE32(const uint8_t* base, uint32_t address) {
  uint32_t value;
  std::memcpy(&value, base + address, 4);
  return std::byteswap(value);
}

std::string GuestString(const uint8_t* base, uint32_t address, size_t limit = 260) {
  std::string text;
  if (address == 0) return text;
  for (size_t i = 0; i < limit; ++i) {
    const char c = static_cast<char>(base[address + i]);
    if (c == '\0') break;
    text.push_back(c);
  }
  return text;
}

// Scratch space for import calls: unused guest stack below the caller's
// frame, well clear of anything live at a function entry.
uint32_t Scratch(const PPCContext& ctx) { return (ctx.r1.u32 - 0x2000u) & ~0xFu; }

// The import helpers read their arguments from r3/r4 and return in r3; the
// guest function being entered still needs its own arguments afterwards.
struct SavedArguments {
  explicit SavedArguments(PPCContext& ctx) : ctx_(ctx) {
    for (size_t i = 0; i < saved_.size(); ++i) saved_[i] = Register(i).u64;
  }
  ~SavedArguments() {
    for (size_t i = 0; i < saved_.size(); ++i) Register(i).u64 = saved_[i];
  }

 private:
  decltype(PPCContext::r3)& Register(size_t i) {
    switch (i) {
      case 0: return ctx_.r3;
      case 1: return ctx_.r4;
      case 2: return ctx_.r5;
      case 3: return ctx_.r6;
      case 4: return ctx_.r7;
      case 5: return ctx_.r8;
      case 6: return ctx_.r9;
      default: return ctx_.r10;
    }
  }
  PPCContext& ctx_;
  std::array<uint64_t, 8> saved_{};
};

std::string StateFile(const char* name) {
  // Relative to the working directory: the launcher runs the game from the
  // package root, whose absolute path may hold non-ASCII characters.
  std::error_code error;
  return std::filesystem::is_directory("logs", error) ? std::string("logs/") + name : std::string(name);
}

// --------------------------------------------------------------- relaunch

std::wstring QuoteArgument(const std::wstring& argument) {
  if (!argument.empty() && argument.find_first_of(L" \t\"") == std::wstring::npos) return argument;
  std::wstring quoted = L"\"";
  size_t backslashes = 0;
  for (const wchar_t c : argument) {
    if (c == L'\\') {
      ++backslashes;
      continue;
    }
    if (c == L'"') quoted.append(backslashes * 2 + 1, L'\\');
    else quoted.append(backslashes, L'\\');
    backslashes = 0;
    quoted.push_back(c);
  }
  quoted.append(backslashes * 2, L'\\');
  quoted.push_back(L'"');
  return quoted;
}

bool StartNextInstance(const std::string& data_file, DWORD& new_pid, HANDLE& new_process) {
  int count = 0;
  wchar_t** argv = CommandLineToArgvW(GetCommandLineW(), &count);
  if (!argv) return false;
  std::wstring command_line;
  for (int i = 0; i < count; ++i) {
    const std::wstring argument = argv[i];
    if (argument.rfind(L"--cod3_launch_data=", 0) == 0 || argument.rfind(L"--cod3_relaunch_wait=", 0) == 0) continue;
    if (!command_line.empty()) command_line.push_back(L' ');
    command_line += QuoteArgument(argument);
  }
  LocalFree(argv);
  command_line += L" " + QuoteArgument(L"--cod3_launch_data=" + std::wstring(data_file.begin(), data_file.end()));
  command_line += L" --cod3_relaunch_wait=" + std::to_wstring(GetCurrentProcessId());

  std::wstring executable(MAX_PATH, L'\0');
  for (;;) {
    const DWORD length = GetModuleFileNameW(nullptr, executable.data(), DWORD(executable.size()));
    if (length == 0) return false;
    if (length < executable.size()) {
      executable.resize(length);
      break;
    }
    executable.resize(executable.size() * 2);
  }

  STARTUPINFOW startup{};
  startup.cb = sizeof(startup);
  // The next instance's window comes up the way this one's did (normal, or
  // minimized when this one was started minimized).
  STARTUPINFOW own{};
  own.cb = sizeof(own);
  GetStartupInfoW(&own);
  if (own.dwFlags & STARTF_USESHOWWINDOW) {
    startup.dwFlags |= STARTF_USESHOWWINDOW;
    startup.wShowWindow = own.wShowWindow;
  }
  PROCESS_INFORMATION process{};
  std::vector<wchar_t> mutable_line(command_line.begin(), command_line.end());
  mutable_line.push_back(L'\0');
  if (!CreateProcessW(executable.c_str(), mutable_line.data(), nullptr, nullptr, FALSE, 0, nullptr, nullptr,
                      &startup, &process)) {
    REXLOG_ERROR("Game: could not start the next instance for the relaunch (error {})", GetLastError());
    return false;
  }
  new_pid = process.dwProcessId;
  new_process = process.hProcess;
  CloseHandle(process.hThread);
  return true;
}

void Relaunch(PPCContext& ctx, uint8_t* base) {
  std::string path = GuestString(base, ctx.r3.u32);
  std::string lower = path;
  std::transform(lower.begin(), lower.end(), lower.begin(), [](unsigned char c) { return char(std::tolower(c)); });
  const std::string self = "default.xex";
  if (lower.size() < self.size() || lower.compare(lower.size() - self.size(), self.size(), self) != 0) {
    REXLOG_INFO("Game: XLaunchNewImage(\"{}\") is not this game; exiting as the console would", path);
    return;
  }

  std::vector<uint8_t> data;
  {
    SavedArguments saved(ctx);
    const uint32_t scratch = Scratch(ctx);
    ctx.r3.u64 = scratch;
    __imp__XamLoaderGetLaunchDataSize(ctx, base);
    const uint32_t size = ctx.r3.u32 == 0 ? LoadBE32(base, scratch) : 0;
    if (size > 0 && size <= kMaxLaunchData) {
      ctx.r3.u64 = scratch + 16;
      ctx.r4.u64 = size;
      __imp__XamLoaderGetLaunchData(ctx, base);
      if (ctx.r3.u32 == 0) data.assign(base + scratch + 16, base + scratch + 16 + size);
    }
  }

  const std::string data_file = StateFile(kLaunchDataFile);
  {
    std::ofstream file(data_file, std::ios::binary | std::ios::trunc);
    file.write(reinterpret_cast<const char*>(data.data()), std::streamsize(data.size()));
    if (!file) {
      REXLOG_ERROR("Game: could not write {} for the relaunch", data_file);
      return;
    }
  }
  // Created before the child exists, so its signal cannot be missed.
  HANDLE ready = CreateEventW(nullptr, TRUE, FALSE, ReadyEventName(GetCurrentProcessId()).c_str());
  DWORD new_pid = 0;
  HANDLE new_process = nullptr;
  if (!StartNextInstance(data_file, new_pid, new_process)) {
    if (ready) CloseHandle(ready);
    return;
  }
  // The launcher follows the game into the new process with this.
  std::ofstream(StateFile(kRelaunchMarker), std::ios::trunc) << GetCurrentProcessId() << ' ' << new_pid << '\n';
  REXLOG_INFO("Game: relaunch for the next level with {} bytes of launch data; continuing in process {}",
              data.size(), new_pid);

  // Keep this window up (showing the last frame) until the next instance
  // draws, so the desktop never shows between levels; stop waiting if it
  // dies or takes too long.
  const auto started = std::chrono::steady_clock::now();
  DWORD outcome = WAIT_FAILED;
  if (ready && new_process) {
    HANDLE handles[2] = {ready, new_process};
    outcome = WaitForMultipleObjects(2, handles, FALSE, 30000);
  }
  const auto waited =
      std::chrono::duration_cast<std::chrono::milliseconds>(std::chrono::steady_clock::now() - started).count();
  if (outcome == WAIT_OBJECT_0) {
    REXLOG_INFO("Game: next instance is on screen after {} ms; handing over", waited);
  } else if (outcome == WAIT_OBJECT_0 + 1) {
    DWORD code = 0;
    GetExitCodeProcess(new_process, &code);
    REXLOG_ERROR("Game: the next instance exited during start-up (code {:#x})", code);
  } else {
    REXLOG_WARN("Game: no word from the next instance after {} ms; handing over anyway", waited);
  }
  if (ready) CloseHandle(ready);
  if (new_process) CloseHandle(new_process);
}

// The relaunched instance: once its game loop runs, give its window a moment
// to show frames and tell the previous instance to go.
void SignalReadySoon() {
  static std::atomic<bool> started{false};
  const unsigned long previous = PreviousInstance();
  if (previous == 0 || started.exchange(true)) return;
  std::thread([previous] {
    std::this_thread::sleep_for(std::chrono::milliseconds(800));
    if (HANDLE ready = OpenEventW(EVENT_MODIFY_STATE, FALSE, ReadyEventName(previous).c_str())) {
      SetEvent(ready);
      CloseHandle(ready);
    }
  }).detach();
}

void HandBackLaunchData(PPCContext& ctx, uint8_t* base) {
  static bool done = false;
  if (done) return;
  done = true;
  const std::string data_file = REXCVAR_GET(cod3_launch_data);
  if (data_file.empty()) return;
  std::ifstream file(data_file, std::ios::binary);
  std::vector<uint8_t> data((std::istreambuf_iterator<char>(file)), std::istreambuf_iterator<char>());
  file.close();
  std::error_code error;
  std::filesystem::remove(data_file, error);
  if (data.empty() || data.size() > kMaxLaunchData) {
    REXLOG_WARN("Game: launch data {} is missing or unusable ({} bytes); starting normally", data_file,
                data.size());
    return;
  }
  SavedArguments saved(ctx);
  const uint32_t scratch = Scratch(ctx);
  std::memcpy(base + scratch, data.data(), data.size());
  ctx.r3.u64 = scratch;
  ctx.r4.u64 = data.size();
  __imp__XamLoaderSetLaunchData(ctx, base);
  REXLOG_INFO("Game: handed {} bytes of launch data from the previous instance back to the game", data.size());
}

}  // namespace

namespace cod3::relaunch {
void NoteGameLoopRunning() { SignalReadySoon(); }
}  // namespace cod3::relaunch

// XLaunchNewImage(path, flags): ends in XamLoaderLaunchTitle, which the SDK
// turns into an exit. The new instance is started first; then the original
// ends this one as before.
REX_EXTERN(sub_82343928) {
  if (REXCVAR_GET(cod3_relaunch)) Relaunch(ctx, base);
  __imp__sub_82343928(ctx, base);
}

// The start-up code that reads the launch data (the only XamLoaderGetLaunchData
// caller) and picks the level to load from it.
REX_EXTERN(sub_823FCCA8) {
  HandBackLaunchData(ctx, base);
  __imp__sub_823FCCA8(ctx, base);
}
