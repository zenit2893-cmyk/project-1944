#include "cod3_vfs_media_map.h"

#include <cstddef>
#include <cstdint>
#include <filesystem>
#include <iostream>
#include <string>
#include <string_view>
#include <system_error>

namespace fs = std::filesystem;
using cod3::vfs_media::ContentAliasObservation;
using cod3::vfs_media::ExpectedConfigFiles;
using cod3::vfs_media::ExpectedMediaFiles;
using cod3::vfs_media::ExpectedMovieFiles;
using cod3::vfs_media::ExpectedRootFiles;
using cod3::vfs_media::kExpectedDirectoryCount;
using cod3::vfs_media::kExpectedFileCount;
using cod3::vfs_media::kExpectedTotalBytes;
using cod3::vfs_media::MountSpec;
using cod3::vfs_media::NormalizeGuestPath;
using cod3::vfs_media::ObservedContentAliases;
using cod3::vfs_media::ObservedMissingPaths;
using cod3::vfs_media::ResolveGamePath;

namespace {

class TestContext {
 public:
  void Check(bool condition, std::string_view message) {
    if (!condition) {
      ++failures_;
      std::cerr << "FAIL: " << message << '\n';
    }
  }

  int failures() const { return failures_; }

 private:
  int failures_ = 0;
};

bool Exists(const fs::path& path) {
  std::error_code ec;
  return fs::exists(path, ec) && !ec;
}

std::uintmax_t FileSize(const fs::path& path, bool* ok) {
  std::error_code ec;
  const auto size = fs::file_size(path, ec);
  *ok = !ec;
  return *ok ? size : 0;
}

void CheckGuestNormalization(TestContext& test) {
  test.Check(NormalizeGuestPath("GAME:\\config\\..\\DEFAULT.CFG") ==
                 "game:/default.cfg",
             "GAME/D separators, case, and dot segments normalize");
  test.Check(NormalizeGuestPath("d:/movies//legal-us.wma/") ==
                 "d:/movies/legal-us.wma",
             "duplicate separators and trailing slash normalize");
  test.Check(NormalizeGuestPath("\\Device\\Harddisk0\\Partition1\\sp\\") ==
                 "/device/harddisk0/partition1/sp",
             "physical mount path normalizes as a guest path");
}

void CheckAliases(TestContext& test, const MountSpec& mount) {
  const auto game = ResolveGamePath(mount, "GAME:\\config\\DEFAULT.CFG");
  const auto partition = ResolveGamePath(mount, "d:/config/default.cfg");
  const auto physical = ResolveGamePath(
      mount, "\\Device\\Harddisk0\\Partition1\\config\\default.cfg");

  test.Check(game.has_value(), "GAME alias resolves");
  test.Check(partition.has_value(), "D alias resolves");
  test.Check(physical.has_value(), "physical mount resolves");
  if (game && partition && physical) {
    test.Check(game->relative_path == "config/default.cfg",
               "GAME alias preserves relative asset path");
    test.Check(game->host_path.lexically_normal() == partition->host_path.lexically_normal(),
               "GAME and D aliases target one host path");
    test.Check(game->host_path.lexically_normal() == physical->host_path.lexically_normal(),
               "physical mount and aliases target one host path");
    test.Check(Exists(game->host_path), "mapped config file exists on disk");
  }

  test.Check(!ResolveGamePath(mount, "cache:/config/default.cfg"),
             "cache alias is outside the game mapping");
  test.Check(!ResolveGamePath(mount, "update:/config/default.cfg"),
             "update alias is outside the game mapping");
  test.Check(!ResolveGamePath(mount, "C:\\config\\default.cfg"),
             "host drive path is not accepted as a guest path");
  test.Check(!ResolveGamePath(mount, "d:\\..\\outside.dat"),
             "parent traversal above D root is rejected");
  test.Check(!ResolveGamePath(mount, "d:/sp/../../outside.dat"),
             "nested traversal above game root is rejected");
}

void CheckSelectedFiles(TestContext& test, const MountSpec& mount,
                         const std::vector<std::string>& paths,
                         std::string_view group_name) {
  for (const auto& relative : paths) {
    const auto resolved = ResolveGamePath(mount, std::string("d:/") + relative);
    test.Check(resolved.has_value(), std::string(group_name) + " path resolves: " + relative);
    if (resolved) {
      test.Check(Exists(resolved->host_path),
                 std::string(group_name) + " source file is present: " + relative);
      std::error_code ec;
      test.Check(fs::is_regular_file(resolved->host_path, ec) && !ec,
                 std::string(group_name) + " source is a regular file: " + relative);
    }
  }
}

void CheckFlatDirectoryFileCount(TestContext& test, const MountSpec& mount,
                                 std::string_view relative_directory,
                                 std::size_t expected_count) {
  const auto resolved = ResolveGamePath(
      mount, std::string("d:/") + std::string(relative_directory));
  test.Check(resolved.has_value(),
             "content directory resolves: " + std::string(relative_directory));
  if (!resolved) {
    return;
  }

  std::error_code ec;
  std::size_t actual_count = 0;
  for (fs::directory_iterator it(resolved->host_path, ec), end; !ec && it != end;
       it.increment(ec)) {
    std::error_code entry_ec;
    if (it->is_regular_file(entry_ec) && !entry_ec) {
      ++actual_count;
    }
  }
  test.Check(!ec, "content directory enumeration completes: " +
                         std::string(relative_directory));
  test.Check(actual_count == expected_count,
             "content directory has the exact extracted file count: " +
                 std::string(relative_directory));
}

void CheckInventory(TestContext& test, const MountSpec& mount) {
  std::error_code ec;
  test.Check(fs::is_directory(mount.host_root, ec) && !ec,
             "game root exists and is a directory");
  if (!fs::is_directory(mount.host_root, ec) || ec) {
    return;
  }

  std::uint32_t files = 0;
  std::uint32_t directories = 0;
  std::uint64_t total_bytes = 0;
  fs::recursive_directory_iterator it(
      mount.host_root, fs::directory_options::skip_permission_denied, ec);
  const fs::recursive_directory_iterator end;
  while (!ec && it != end) {
    std::error_code entry_ec;
    if (it->is_regular_file(entry_ec) && !entry_ec) {
      ++files;
      bool size_ok = false;
      const auto size = FileSize(it->path(), &size_ok);
      test.Check(size_ok, "all extracted files can be stat'ed");
      total_bytes += size;
    } else if (it->is_directory(entry_ec) && !entry_ec) {
      ++directories;
    }
    it.increment(ec);
  }
  test.Check(!ec, "recursive inventory completes without an enumeration error");
  test.Check(files == kExpectedFileCount, "extracted file count is 553");
  test.Check(directories == kExpectedDirectoryCount, "extracted directory count is 41");
  test.Check(total_bytes == kExpectedTotalBytes,
             "extracted byte total matches the verified manifest");

  CheckSelectedFiles(test, mount, ExpectedRootFiles(), "root");
  CheckSelectedFiles(test, mount, ExpectedConfigFiles(), "config");
  CheckSelectedFiles(test, mount, ExpectedMediaFiles(), "media");
  CheckSelectedFiles(test, mount, ExpectedMovieFiles(), "movies");
  CheckFlatDirectoryFileCount(test, mount, "", ExpectedRootFiles().size());
  CheckFlatDirectoryFileCount(test, mount, "config", ExpectedConfigFiles().size());
  CheckFlatDirectoryFileCount(test, mount, "media", ExpectedMediaFiles().size());
  CheckFlatDirectoryFileCount(test, mount, "movies", ExpectedMovieFiles().size());
}

void CheckExpectedMisses(TestContext& test, const MountSpec& mount) {
  for (const auto& guest_path : ObservedMissingPaths()) {
    const auto resolved = ResolveGamePath(mount, guest_path);
    test.Check(resolved.has_value(), "observed miss still resolves lexically: " + guest_path);
    if (resolved) {
      // This is the key non-stubbing assertion: the requested file remains
      // absent, and its path is not silently rewritten to another asset.
      test.Check(!Exists(resolved->host_path), "observed miss is absent: " + guest_path);
    }
  }

  for (const ContentAliasObservation& alias : ObservedContentAliases()) {
    test.Check(!alias.enabled, "content alias remains disabled: " + alias.requested);
    const auto requested = ResolveGamePath(mount, alias.requested);
    test.Check(requested.has_value(), "content alias request resolves lexically: " + alias.requested);
    if (requested) {
      if (!alias.candidate.empty()) {
        test.Check(requested->relative_path != alias.candidate.substr(3),
                   "content alias does not rewrite the requested relative path: " +
                       alias.requested);
      }
      test.Check(!Exists(requested->host_path),
                 "disabled content alias remains an observable missing file: " +
                     alias.requested);
    }
  }
}

}  // namespace

int Run(const fs::path& game_root) {
  MountSpec mount{game_root};
  TestContext test;

  CheckGuestNormalization(test);
  CheckAliases(test, mount);
  CheckInventory(test, mount);
  CheckExpectedMisses(test, mount);

  if (test.failures() != 0) {
    std::cerr << "cod3_vfs_media_tests: " << test.failures() << " failure(s)\n";
    return 1;
  }

  std::cout << "cod3_vfs_media_tests: PASS\n"
            << "game_root_checked=1\n"
            << "inventory_files=" << kExpectedFileCount << '\n'
            << "inventory_directories=" << kExpectedDirectoryCount << '\n'
            << "inventory_bytes=" << kExpectedTotalBytes << '\n'
            << "observed_missing_paths=" << ObservedMissingPaths().size() << '\n'
            << "content_aliases_enabled=0\n";
  return 0;
}

#ifdef _WIN32
int wmain(int argc, wchar_t** argv) {
  const fs::path game_root = argc > 1 ? fs::path(argv[1])
                                      : fs::current_path() / "game" / "cod3";
  return Run(game_root);
}
#else
int main(int argc, char** argv) {
  const fs::path game_root = argc > 1 ? fs::path(argv[1])
                                      : fs::current_path() / "game" / "cod3";
  return Run(game_root);
}
#endif
