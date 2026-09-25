/**
 * Read-only path mapping for the extracted Call of Duty 3 data tree.
 *
 * This adapter mirrors the small part of Xenia's VFS contract that the
 * native port needs for an extracted XEX: GAME: and D: resolve to the same
 * host directory, while path spelling is case-insensitive and separator
 * agnostic. It intentionally does not invent files for optional or missing
 * content.
 */

#pragma once

#include <cstdint>
#include <filesystem>
#include <optional>
#include <string>
#include <string_view>
#include <vector>

namespace cod3::vfs_media {

inline constexpr std::string_view kGameAlias = "game:";
inline constexpr std::string_view kPartitionAlias = "d:";
inline constexpr std::string_view kPhysicalMount =
    "\\Device\\Harddisk0\\Partition1";

// These counts are metadata from the verified XDVDFS extraction. They do not
// embed or redistribute any game bytes.
inline constexpr std::uint32_t kExpectedFileCount = 553;
inline constexpr std::uint32_t kExpectedDirectoryCount = 41;
inline constexpr std::uint64_t kExpectedTotalBytes = 6193138297ULL;

struct MountSpec {
  std::filesystem::path host_root;
  std::string physical_mount{ kPhysicalMount };
};

struct ResolvedPath {
  // Canonical spelling after Xenia-style separator and dot-segment handling.
  std::string canonical_guest_path;
  // Canonical path relative to the selected game root, using '/'.
  std::string relative_path;
  std::filesystem::path host_path;
};

/**
 * Normalize a guest path for comparisons.
 *
 * The result uses '/', ASCII lowercase, collapsed separators, and resolved
 * '.'/'..' segments. A device component such as `d:` is kept as the first
 * component, matching Xenia's canonicalize_guest_path convention.
 */
std::string NormalizeGuestPath(std::string_view path);

/**
 * Resolve a GAME:/D:/physical-mount path against a host game root.
 *
 * Returns nullopt for unknown devices, host-absolute paths, malformed
 * components, or traversal that would escape the game root. Resolution is
 * lexical and read-only; it does not create directories or claim that the
 * resulting file exists.
 */
std::optional<ResolvedPath> ResolveGamePath(const MountSpec& mount,
                                            std::string_view guest_path);

// The exact files in the small root/config/media/movies portion used by the
// startup path. Paths are canonical guest-relative spellings.
const std::vector<std::string>& ExpectedRootFiles();
const std::vector<std::string>& ExpectedConfigFiles();
const std::vector<std::string>& ExpectedMediaFiles();
const std::vector<std::string>& ExpectedMovieFiles();

// Paths observed as failed NtCreateFile requests in the last reviewed native
// probe. They are expected misses for this disc revision, not successful
// fallback targets.
const std::vector<std::string>& ObservedMissingPaths();

struct ContentAliasObservation {
  std::string requested;
  std::string candidate;
  bool enabled;
  std::string reason;
};

// Candidate content aliases are data for review only. All are disabled until
// the title's language selection and byte equivalence are independently
// verified. The resolver above never applies these observations.
const std::vector<ContentAliasObservation>& ObservedContentAliases();

}  // namespace cod3::vfs_media
