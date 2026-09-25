// The game's own console output, copied into the log.
//
// The retail build compiled its print functions down to a bare blr, but every
// call site still loads the format string and arguments. Hooking those stubs
// and formatting the guest varargs here recovers the messages - AI, path,
// script, asset and spawn warnings - without changing what the game does.
//
// Xbox 360 varargs: the format string is r3, the next seven 64-bit slots are
// r4-r10, and the rest sit in the caller's parameter save area at
// r1 + 16 + 8 * n. Doubles travel as raw bits in the same slots.

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

#include <algorithm>
#include <bit>
#include <chrono>
#include <cstdint>
#include <cstdio>
#include <cstring>
#include <mutex>
#include <string>
#include <string_view>

REXCVAR_DEFINE_BOOL(cod3_game_console, false, "Game",
                    "Copy the game's own console, developer and script messages into the log");

REX_EXTERN(__imp__sub_82523A60);
REX_EXTERN(__imp__sub_82523A58);
REX_EXTERN(__imp__sub_82539570);
REX_EXTERN(__imp__sub_82539578);
REX_EXTERN(__imp__sub_82144CA8);
REX_EXTERN(__imp__sub_82539518);
REX_EXTERN(__imp__sub_82127938);

namespace {

enum class Level { kDebug, kInfo, kWarn, kError };

struct Channel {
  const char* name;
  Level level;
};

// Stub address -> what its call sites print (from the strings they pass).
constexpr Channel kConsole{"console", Level::kInfo};     // Com_Printf
constexpr Channel kDeveloper{"developer", Level::kDebug};  // Com_DPrintf
constexpr Channel kScript{"script", Level::kInfo};       // script/AI runtime notes
constexpr Channel kPath{"path", Level::kInfo};           // path/node data notes
constexpr Channel kDump{"dump", Level::kDebug};          // debug table dumps
constexpr Channel kError{"error", Level::kWarn};         // G_Error-style texts
constexpr Channel kFatal{"fatal", Level::kError};        // "TL Fatal Error"

constexpr size_t kMaxText = 2048;
constexpr uint32_t kMaxLinesPerSecond = 400;

// Guest pointers come from the game; a stray one must not take the host down.
class GuestReader {
 public:
  explicit GuestReader(uint8_t* base) : base_(base) {}

  bool Readable(uint32_t address, size_t size) {
    if (address == 0) return false;
    const uint8_t* start = base_ + address;
    if (start >= ok_begin_ && start + size <= ok_end_) return true;
    MEMORY_BASIC_INFORMATION info{};
    if (!VirtualQuery(start, &info, sizeof(info))) return false;
    constexpr DWORD kReadable = PAGE_READONLY | PAGE_READWRITE | PAGE_WRITECOPY | PAGE_EXECUTE_READ |
                                PAGE_EXECUTE_READWRITE | PAGE_EXECUTE_WRITECOPY;
    if (info.State != MEM_COMMIT || (info.Protect & PAGE_GUARD) || !(info.Protect & kReadable)) return false;
    ok_begin_ = static_cast<const uint8_t*>(info.BaseAddress);
    ok_end_ = ok_begin_ + info.RegionSize;
    return start + size <= ok_end_;
  }

  bool String(uint32_t address, std::string& out) {
    out.clear();
    for (size_t i = 0; i < kMaxText; ++i) {
      if (!Readable(address + static_cast<uint32_t>(i), 1)) return i != 0;
      const char c = static_cast<char>(base_[address + i]);
      if (c == '\0') return true;
      out.push_back(c);
    }
    return true;
  }

  bool U64(uint32_t address, uint64_t& value) {
    if (!Readable(address, 8)) return false;
    std::memcpy(&value, base_ + address, 8);
    value = std::byteswap(value);
    return true;
  }

 private:
  uint8_t* base_;
  const uint8_t* ok_begin_ = nullptr;
  const uint8_t* ok_end_ = nullptr;
};

class GuestArgs {
 public:
  GuestArgs(PPCContext& ctx, GuestReader& reader) : ctx_(ctx), reader_(reader) {}

  uint64_t Next() {
    switch (++index_) {
      case 1: return ctx_.r4.u64;
      case 2: return ctx_.r5.u64;
      case 3: return ctx_.r6.u64;
      case 4: return ctx_.r7.u64;
      case 5: return ctx_.r8.u64;
      case 6: return ctx_.r9.u64;
      case 7: return ctx_.r10.u64;
      default: break;
    }
    uint64_t value = 0;
    reader_.U64(ctx_.r1.u32 + 16 + 8 * index_, value);
    return value;
  }

 private:
  PPCContext& ctx_;
  GuestReader& reader_;
  uint32_t index_ = 0;
};

template <typename T>
void AppendFormatted(std::string& out, const std::string& spec, T value) {
  char buffer[kMaxText];
  const int written = std::snprintf(buffer, sizeof(buffer), spec.c_str(), value);
  if (written > 0) out.append(buffer, std::min<size_t>(static_cast<size_t>(written), sizeof(buffer) - 1));
}

// The linker folded every empty function of the game into a few shared blr
// stubs, so a stub also serves no-op calls that pass a struct pointer in r3
// (about 30 a second during play). Every real format string in the game is
// short plain ASCII; anything else is not a message.
bool LooksLikeFormat(const std::string& text) {
  if (text.empty() || text.size() >= kMaxText) return false;
  for (const char c : text) {
    const auto byte = static_cast<unsigned char>(c);
    if ((byte < 0x20 && c != '\n' && c != '\t' && c != '\r') || byte > 0x7E) return false;
  }
  return true;
}

// printf for guest varargs: every conversion is rebuilt as a host spec and
// fed the matching slot, so width/precision/flags behave as in the game.
std::string FormatGuest(PPCContext& ctx, uint8_t* base) {
  GuestReader reader(base);
  std::string format;
  if (!reader.String(ctx.r3.u32, format) || !LooksLikeFormat(format)) return {};
  GuestArgs args(ctx, reader);

  std::string out;
  size_t i = 0;
  const auto digits = [&](std::string& spec) {
    while (i < format.size() && format[i] >= '0' && format[i] <= '9') spec += format[i++];
  };
  while (i < format.size() && out.size() < kMaxText) {
    if (format[i] != '%') {
      out += format[i++];
      continue;
    }
    const size_t start = i++;
    if (i < format.size() && format[i] == '%') {
      out += '%';
      ++i;
      continue;
    }
    std::string spec = "%";
    while (i < format.size() && format[i] != '\0' && std::strchr("-+ #0", format[i])) spec += format[i++];
    if (i < format.size() && format[i] == '*') {
      spec += std::to_string(std::clamp(static_cast<int32_t>(args.Next()), -512, 512));
      ++i;
    } else {
      digits(spec);
    }
    if (i < format.size() && format[i] == '.') {
      spec += format[i++];
      if (i < format.size() && format[i] == '*') {
        spec += std::to_string(std::clamp(static_cast<int32_t>(args.Next()), 0, 512));
        ++i;
      } else {
        digits(spec);
      }
    }
    bool wide = false;
    while (i < format.size()) {
      if (format.compare(i, 2, "ll") == 0) {
        wide = true;
        i += 2;
      } else if (format.compare(i, 3, "I64") == 0) {
        wide = true;
        i += 3;
      } else if (format[i] != '\0' && std::strchr("hlLqjzt", format[i])) {
        wide = wide || format[i] == 'q' || format[i] == 'j';
        ++i;
      } else {
        break;
      }
    }
    if (i >= format.size()) {
      out.append(format, start, std::string::npos);
      break;
    }
    const char conversion = format[i++];
    switch (conversion) {
      case 'd':
      case 'i': {
        const uint64_t value = args.Next();
        if (wide) {
          AppendFormatted(out, spec + "lld", static_cast<long long>(value));
        } else {
          AppendFormatted(out, spec + "d", static_cast<int32_t>(static_cast<uint32_t>(value)));
        }
        break;
      }
      case 'u':
      case 'x':
      case 'X':
      case 'o': {
        const uint64_t value = args.Next();
        if (wide) {
          AppendFormatted(out, spec + "ll" + conversion, static_cast<unsigned long long>(value));
        } else {
          AppendFormatted(out, spec + conversion, static_cast<uint32_t>(value));
        }
        break;
      }
      case 'c':
        AppendFormatted(out, spec + "c", static_cast<int>(static_cast<uint8_t>(args.Next())));
        break;
      case 'e':
      case 'E':
      case 'f':
      case 'F':
      case 'g':
      case 'G':
      case 'a':
      case 'A':
        AppendFormatted(out, spec + conversion, std::bit_cast<double>(args.Next()));
        break;
      case 's':
      case 'S': {
        const uint32_t pointer = static_cast<uint32_t>(args.Next());
        std::string text;
        if (pointer == 0) {
          text = "(null)";
        } else if (!reader.String(pointer, text)) {
          text = "(bad pointer)";
        }
        AppendFormatted(out, spec + "s", text.c_str());
        break;
      }
      case 'p':
        AppendFormatted(out, std::string("%08X"), static_cast<uint32_t>(args.Next()));
        break;
      case 'n':
        args.Next();  // never write through a guest pointer
        break;
      default:
        out.append(format, start, i - start);
        break;
    }
  }
  if (out.size() > kMaxText) out.resize(kMaxText);
  return out;
}

class Sink {
 public:
  // whole: the text is a complete message even without a trailing newline.
  void Write(const Channel& channel, std::string_view text, bool whole) {
    std::lock_guard lock(mutex_);
    if (!pending_.empty() && pending_channel_ != &channel) FlushLine(*pending_channel_);
    // Color codes (^1 red, ^3 yellow...) only matter on the in-game console.
    for (size_t i = 0; i < text.size(); ++i) {
      const char c = text[i];
      if (c == '^' && i + 1 < text.size() && text[i + 1] >= '0' && text[i + 1] <= '9') {
        ++i;
        continue;
      }
      if (c == '\n') {
        FlushLine(channel);
        continue;
      }
      if (c == '\r') continue;
      pending_ += (static_cast<unsigned char>(c) < 0x20 && c != '\t') ? ' ' : c;
      pending_channel_ = &channel;
    }
    // Com_Printf is often fed a line in pieces; hold the tail until its '\n'
    // unless another channel interleaves or it grows past any sane length.
    if (!pending_.empty() && (whole || pending_.size() > kMaxText)) FlushLine(channel);
  }

 private:
  void FlushLine(const Channel& channel) {
    std::string line = std::move(pending_);
    pending_.clear();
    const Channel& owner = pending_channel_ ? *pending_channel_ : channel;
    pending_channel_ = nullptr;
    const size_t first = line.find_first_not_of(" \t");
    if (first == std::string::npos) return;
    line.erase(0, first);
    line.erase(line.find_last_not_of(" \t") + 1);

    if (line == last_line_ && &owner == last_channel_) {
      ++repeats_;
      return;
    }
    FlushRepeats();

    const auto now = std::chrono::steady_clock::now();
    if (now - window_start_ >= std::chrono::seconds(1)) {
      if (dropped_) {
        REXLOG_WARN("Game log: {} messages dropped (over {} per second)", dropped_, kMaxLinesPerSecond);
      }
      window_start_ = now;
      lines_in_window_ = 0;
      dropped_ = 0;
    }
    if (++lines_in_window_ > kMaxLinesPerSecond) {
      ++dropped_;
      return;
    }
    Emit(owner, line);
    last_line_ = std::move(line);
    last_channel_ = &owner;
  }

  void FlushRepeats() {
    if (repeats_ && last_channel_) {
      REXLOG_INFO("Game {}: (previous message repeated {} more times)", last_channel_->name, repeats_);
    }
    repeats_ = 0;
  }

  static void Emit(const Channel& channel, const std::string& line) {
    Level level = channel.level;
    if (level == Level::kInfo &&
        (line.find("ERROR") != std::string::npos || line.find("WARNING") != std::string::npos ||
         line.find("Error") != std::string::npos)) {
      level = Level::kWarn;
    }
    switch (level) {
      case Level::kDebug: REXLOG_DEBUG("Game {}: {}", channel.name, line); break;
      case Level::kInfo: REXLOG_INFO("Game {}: {}", channel.name, line); break;
      case Level::kWarn: REXLOG_WARN("Game {}: {}", channel.name, line); break;
      case Level::kError: REXLOG_ERROR("Game {}: {}", channel.name, line); break;
    }
  }

  std::mutex mutex_;
  std::string pending_;
  const Channel* pending_channel_ = nullptr;
  std::string last_line_;
  const Channel* last_channel_ = nullptr;
  uint32_t repeats_ = 0;
  std::chrono::steady_clock::time_point window_start_{};
  uint32_t lines_in_window_ = 0;
  uint32_t dropped_ = 0;
};

Sink& GetSink() {
  static Sink sink;
  return sink;
}

// Formats before the original runs: once it returns, r4-r10 are clobbered.
void Capture(const Channel& channel, PPCContext& ctx, uint8_t* base, bool always = false) {
  if (!always && !REXCVAR_GET(cod3_game_console)) return;
  const std::string text = FormatGuest(ctx, base);
  if (text.empty()) return;
  // G_Error-style and fatal texts have no trailing newline; they are whole.
  GetSink().Write(channel, text, channel.level >= Level::kWarn);
}

}  // namespace

REX_EXTERN(sub_82523A60) {
  Capture(kConsole, ctx, base);
  __imp__sub_82523A60(ctx, base);
}

REX_EXTERN(sub_82523A58) {
  Capture(kDeveloper, ctx, base);
  __imp__sub_82523A58(ctx, base);
}

REX_EXTERN(sub_82539570) {
  Capture(kScript, ctx, base);
  __imp__sub_82539570(ctx, base);
}

REX_EXTERN(sub_82539578) {
  Capture(kPath, ctx, base);
  __imp__sub_82539578(ctx, base);
}

REX_EXTERN(sub_82144CA8) {
  Capture(kDump, ctx, base);
  __imp__sub_82144CA8(ctx, base);
}

// Formats into a stack buffer and throws it away; the caller then errors out.
REX_EXTERN(sub_82539518) {
  Capture(kError, ctx, base);
  __imp__sub_82539518(ctx, base);
}

// "TL Fatal Error: <text>" sink of the engine library (r3 = finished text).
// Rare and always worth having, so it is logged even without the cvar.
REX_EXTERN(sub_82127938) {
  GuestReader reader(base);
  std::string text;
  if (reader.String(ctx.r3.u32, text) && LooksLikeFormat(text)) GetSink().Write(kFatal, text, true);
  __imp__sub_82127938(ctx, base);
}
