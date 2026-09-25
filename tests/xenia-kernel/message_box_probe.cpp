#include <array>
#include <chrono>
#include <cstdlib>
#include <cstring>
#include <filesystem>
#include <future>
#include <iostream>
#include <memory>
#include <string>
#include <string_view>
#include <vector>

#include <rex/cvar.h>
#include <rex/kernel/init.h>
#include <rex/logging.h>
#include <rex/ppc/function.h>
#include <rex/runtime.h>
#include <rex/system/xevent.h>
#include <rex/system/xio.h>
#include <rex/system/xthread.h>

REXCVAR_DECLARE(bool, headless);

using rex::X_RESULT;
using rex::X_STATUS;

namespace rex::kernel::xam {
// The real normal-UI entry is exported by the unmodified SDK. The exact
// candidate Ex adapter is extracted at configure time, not copied into tests.
u32 XamShowMessageBoxUI_entry(u32, mapped_wstring, mapped_wstring, u32,
                             mapped_u32, u32, u32, mapped_u32, mapped_void);
#define XamShowMessageBoxUIEx_entry Cod3CandidateMessageBoxUIEx_entry
#include "candidate_adapter.inl"
#undef XamShowMessageBoxUIEx_entry
}  // namespace rex::kernel::xam

// The combined-runtime mode calls the actual raw export from the candidate
// heap-fixed runtime DLL. The default mode calls the isolated typed adapter so
// the ABI contract remains testable against the unmodified SDK as well.
REX_EXTERN(__imp__XamShowMessageBoxUIEx);

namespace {
std::vector<std::pair<std::string, bool>> checks;
bool use_runtime_export = false;

bool Check(bool value, const char* name) {
  checks.emplace_back(name, value);
  std::cout << (value ? "PASS " : "FAIL ") << name << '\n';
  return value;
}

[[noreturn]] void Finish(int exit_code) {
  size_t passed = 0;
  for (auto& [name, value] : checks) passed += value;
  std::cout << "RESULT " << passed << "/" << checks.size() << " passed\n";
  std::cout << "SCOPE actual candidate adapter + real unmodified SDK UI and "
               "deferred event completion; no guest game entry, GUI, CPU JIT, "
               "physics or FPS measurement\n";
  rex::FlushLogging();
  std::cout.flush();
  // Like the existing isolated loader probe, process exit is intentional:
  // runtime teardown is a different contract, not under test here.
  std::_Exit(exit_code);
}

void Store32(uint8_t* base, uint32_t address, uint32_t value) {
  rex::memory::store_and_swap<uint32_t>(base + address, value);
}
uint32_t Load32(uint8_t* base, uint32_t address) {
  return rex::memory::load_and_swap<uint32_t>(base + address);
}
void String16(uint8_t* base, uint32_t address, std::u16string_view text) {
  for (size_t i = 0; i < text.size(); ++i) {
    rex::memory::store_and_swap<uint16_t>(base + address + i * 2, text[i]);
  }
  rex::memory::store_and_swap<uint16_t>(base + address + text.size() * 2, 0);
}

void Invoke(PPCContext& ctx, uint8_t* base, uint32_t fixture, uint32_t active,
            uint32_t unused, uint32_t overlapped) {
  // Manually reproduce PPC argument locations visible in CoD3 sub_823449D0.
  // Independent of ArgTranslator::SetValue, so this catches stack ABI errors.
  ctx.r3.u64 = 255;
  ctx.r4.u64 = 0;  // CoD3 passes a null title.
  ctx.r5.u64 = fixture + 0x100;
  ctx.r6.u64 = 2;
  ctx.r7.u64 = fixture + 0x200;
  ctx.r8.u64 = active;
  ctx.r9.u64 = 1;
  ctx.r10.u64 = unused;
  Store32(base, ctx.r1.u32 + 0x50, 0xBAD00050);
  Store32(base, ctx.r1.u32 + 0x54, fixture + 0x300);
  Store32(base, ctx.r1.u32 + 0x58, 0xBAD00058);
  Store32(base, ctx.r1.u32 + 0x5C, overlapped);
  if (use_runtime_export) {
    __imp__XamShowMessageBoxUIEx(ctx, base);
  } else {
    rex::ppc::HostToGuestFunction<
        rex::kernel::xam::Cod3CandidateMessageBoxUIEx_entry>(ctx, base);
  }
}

int RunContracts(rex::Runtime& runtime) {
  using namespace rex::system;
  auto* memory = runtime.memory();
  auto* base = runtime.virtual_membase();
  const uint32_t fixture = memory->SystemHeapAlloc(0x1000);
  if (!Check(fixture != 0, "fixture allocated in guest memory")) return 1;
  std::memset(base + fixture, 0, 0x1000);
  String16(base, fixture + 0x100, u"Native adapter contract probe");
  String16(base, fixture + 0x220, u"First");
  String16(base, fixture + 0x240, u"Second");
  Store32(base, fixture + 0x200, fixture + 0x220);
  Store32(base, fixture + 0x204, fixture + 0x240);
  Store32(base, fixture + 0x2FC, 0x12345678);
  Store32(base, fixture + 0x304, 0x87654321);

  PPCContext ctx{};
  ctx.r1.u64 = fixture + 0x800;
  ctx.r13 = rex::runtime::ThreadState::Get()->context()->r13;
  ctx.r31.u64 = 0xC0DEC0DE12345678ull;
  ctx.lr = 0x82344A5C;

  REXCVAR_SET(headless, true);
  Store32(base, fixture + 0x300, 0xFFFFFFFF);
  Invoke(ctx, base, fixture, 1, 0xDEADBEEF, 0);
  Check(ctx.r3.u64 == X_ERROR_SUCCESS, "synchronous adapter returns real UI status");
  Check(Load32(base, fixture + 0x300) == 1, "ninth argument receives selected button in big endian");
  Check(ctx.r31.u64 == 0xC0DEC0DE12345678ull && ctx.r1.u64 == fixture + 0x800 &&
            ctx.lr == 0x82344A5C,
        "wrapper preserves nonvolatile register, stack pointer and LR");
  Check(Load32(base, fixture + 0x2FC) == 0x12345678 &&
            Load32(base, fixture + 0x304) == 0x87654321,
        "message-box result writes exactly one guest DWORD");
  Check(Load32(base, ctx.r1.u32 + 0x50) == 0xBAD00050 &&
            Load32(base, ctx.r1.u32 + 0x58) == 0xBAD00058,
        "PPC stack padding remains untouched");

  auto event = object_ref<XEvent>(new XEvent(runtime.kernel_state()));
  event->Initialize(true, false);
  auto* overlapped = reinterpret_cast<XAM_OVERLAPPED*>(base + fixture + 0x400);
  std::memset(overlapped, 0, sizeof(*overlapped));
  overlapped->event = event->handle();
  Store32(base, fixture + 0x300, 0xFFFFFFFF);
  const uint32_t originating_thread = XThread::GetCurrentThreadHandle();
  Invoke(ctx, base, fixture, 0, 1, fixture + 0x400);
  Check(ctx.r3.u64 == X_ERROR_IO_PENDING,
        "asynchronous adapter returns IO_PENDING 997 required by CoD3");
  uint64_t timeout = static_cast<uint64_t>(-50000000ll);  // Five seconds.
  const X_STATUS wait = event->Wait(0, 0, 0, &timeout);
  if (!Check(wait == X_STATUS_SUCCESS, "real deferred completion signals guest event")) return 1;
  Check(Load32(base, fixture + 0x300) == 0,
        "deferred completion writes selected button through ninth argument");
  Check(overlapped->result == X_ERROR_SUCCESS && overlapped->extended_error == 0 &&
            overlapped->length == 0,
        "tenth argument receives result, extended error and length");
  Check(overlapped->context == originating_thread,
        "overlapped stores originating guest thread handle");

  // Exercise the normal UI's existing no-drawer fallback without opening UI.
  REXCVAR_SET(headless, false);
  Store32(base, fixture + 0x300, 0xFFFFFFFF);
  Invoke(ctx, base, fixture, 1, 0, 0);
  Check(ctx.r3.u64 == X_ERROR_SUCCESS && Load32(base, fixture + 0x300) == 1,
        "missing ImGui drawer follows real synchronous fallback");
  for (auto& [name, value] : checks) if (!value) return 1;
  return 0;
}
}  // namespace

int wmain(int argc, wchar_t** argv) {
  if (argc < 2 || argc > 3) return 64;
  if (argc == 3) {
    if (std::wstring_view(argv[2]) != L"--runtime-export") return 64;
    use_runtime_export = true;
  }
  rex::InitLogging(nullptr, spdlog::level::warn);
  const std::filesystem::path root(argv[1]);
  auto runtime = std::make_unique<rex::Runtime>(root);
  rex::RuntimeConfig config;
  config.kernel_init = rex::kernel::InitializeKernel;
  config.tool_mode = true;
  if (!Check(runtime->Setup(std::move(config)) == 0, "tool runtime initializes without GPU")) Finish(1);
  // Reads original XEX metadata and starts the SDK deferred worker only.
  // LaunchModule/PrepareModuleLaunch are deliberately never called.
  if (!Check(runtime->LoadXexImage("game:/default.xex") == 0,
             "XEX metadata loads without executing guest entry")) Finish(1);
  std::promise<int> completion;
  auto done = completion.get_future();
  auto worker = rex::system::object_ref<rex::system::XHostThread>(
      new rex::system::XHostThread(runtime->kernel_state(), 128 * 1024, 0, [&] {
        const int result = RunContracts(*runtime);
        completion.set_value(result);
        return result;
      }));
  worker->set_name("Isolated XAM contract probe");
  if (!Check(worker->Create() == 0, "native SDK worker starts for kernel contract")) Finish(1);
  if (done.wait_for(std::chrono::seconds(12)) != std::future_status::ready) {
    Check(false, "kernel contract finishes within 12 seconds");
    Finish(1);
  }
  Finish(done.get());
}
