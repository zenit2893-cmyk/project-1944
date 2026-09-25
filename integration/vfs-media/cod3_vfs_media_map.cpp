#include "cod3_vfs_media_map.h"

#include <algorithm>
#include <cctype>
#include <string>
#include <vector>

namespace cod3::vfs_media {
namespace {

std::string FixSeparatorsAndLower(std::string_view input) {
  std::string result;
  result.reserve(input.size());

  bool previous_separator = false;
  for (const unsigned char value : input) {
    if (value == '/' || value == '\\') {
      if (!previous_separator) {
        result.push_back('/');
      }
      previous_separator = true;
      continue;
    }
    previous_separator = false;
    result.push_back(static_cast<char>(std::tolower(value)));
  }

  while (result.size() > 1 && result.back() == '/') {
    result.pop_back();
  }
  return result;
}

std::vector<std::string> Split(const std::string& path) {
  std::vector<std::string> parts;
  std::size_t begin = 0;
  while (begin < path.size()) {
    while (begin < path.size() && path[begin] == '/') {
      ++begin;
    }
    if (begin == path.size()) {
      break;
    }
    const auto end = path.find('/', begin);
    const auto length = end == std::string::npos ? path.size() - begin : end - begin;
    parts.emplace_back(path.substr(begin, length));
    begin = end == std::string::npos ? path.size() : end + 1;
  }
  return parts;
}

bool EndsWithColon(const std::string& value) {
  return !value.empty() && value.back() == ':';
}

std::string Join(const std::vector<std::string>& parts, bool rooted) {
  std::string result;
  if (rooted) {
    result.push_back('/');
  }
  for (std::size_t i = 0; i < parts.size(); ++i) {
    if (i != 0) {
      result.push_back('/');
    }
    result += parts[i];
  }
  return result;
}

bool StartsWithComponent(const std::string& path, const std::string& prefix,
                         std::string* suffix) {
  if (path == prefix) {
    if (suffix) {
      suffix->clear();
    }
    return true;
  }
  if (path.size() <= prefix.size() || path.compare(0, prefix.size(), prefix) != 0 ||
      path[prefix.size()] != '/') {
    return false;
  }
  if (suffix) {
    *suffix = path.substr(prefix.size() + 1);
  }
  return true;
}

bool HasRootEscape(const std::string& relative) {
  std::size_t depth = 0;
  for (const auto& part : Split(relative)) {
    if (part.empty() || part == ".") {
      continue;
    }
    if (part == "..") {
      if (depth == 0) {
        return true;
      }
      --depth;
      continue;
    }
    ++depth;
  }
  return false;
}

std::optional<std::string> CanonicalizeRelative(const std::string& relative) {
  if (HasRootEscape(relative)) {
    return std::nullopt;
  }

  std::vector<std::string> parts;
  for (const auto& part : Split(relative)) {
    if (part.empty() || part == ".") {
      continue;
    }
    if (part == "..") {
      if (parts.empty()) {
        return std::nullopt;
      }
      parts.pop_back();
      continue;
    }
    // A colon in a relative component would be interpreted as a Windows
    // device/stream component, so it is never a game asset path.
    if (part.find(':') != std::string::npos) {
      return std::nullopt;
    }
    parts.push_back(part);
  }
  return Join(parts, false);
}

const std::vector<std::string> kRootFiles = {
    "codmp_xenonf.xex",
    "default.xex",
};

const std::vector<std::string> kConfigFiles = {
    "config/default.cfg",
    "config/mp_xenon_a.cfg",
    "config/mp_xenon_b.cfg",
    "config/mp_xenon_c.cfg",
    "config/mp_xenon_d.cfg",
    "config/ts_def.cfg",
    "config/ts_leg.cfg",
    "config/ts_legsp.cfg",
    "config/ts_sp.cfg",
    "config/xenon_a.cfg",
    "config/xenon_b.cfg",
    "config/xenon_c.cfg",
    "config/xenon_d.cfg",
};

const std::vector<std::string> kMediaFiles = {
    "media/gara.ttf",
};

const std::vector<std::string> kMovieFiles = {
    "movies/attract.wma",
    "movies/attract.wmv",
    "movies/atvi.wma",
    "movies/atvi.wmv",
    "movies/blkbrn-en.wma",
    "movies/blkbrn.wmv",
    "movies/chambois-en.wma",
    "movies/chambois.wmv",
    "movies/crssrds-en.wma",
    "movies/crssrds.wmv",
    "movies/falaise-en.wma",
    "movies/falaise.wmv",
    "movies/finale-en.wma",
    "movies/finale.wmv",
    "movies/forest-en.wma",
    "movies/forest.wmv",
    "movies/fuelplnt-en.wma",
    "movies/fuelplnt.wmv",
    "movies/hostage-en.wma",
    "movies/hostage.wmv",
    "movies/island-en.wma",
    "movies/island.wmv",
    "movies/laison-en.wma",
    "movies/laison.wmv",
    "movies/legal-uk.wma",
    "movies/legal-uk.wmv",
    "movies/legal-us.wma",
    "movies/legal-us.wmv",
    "movies/mace2-en.wma",
    "movies/mace2.wmv",
    "movies/mayenne-en.wma",
    "movies/mayenne.wmv",
    "movies/nightd-en.wma",
    "movies/nightd.wmv",
    "movies/saint_lo-en.wma",
    "movies/saint_lo.wmv",
    "movies/stbert-en.wma",
    "movies/stbert.wmv",
    "movies/treyarch.wma",
    "movies/treyarch.wmv",
};

const std::vector<std::string> kMissingPaths = {
    "d:/_british/",
    "d:/_chinese/",
    "d:/_english/",
    "d:/_french/",
    "d:/_german/",
    "d:/_italian/",
    "d:/_japanese/",
    "d:/_korean/",
    "d:/_leet/",
    "d:/_polish/",
    "d:/_russian/",
    "d:/_spanish/",
    "d:/_taiwanese/",
    "d:/_thai/",
    "d:/config/autoexec.cfg",
    "d:/config/bro.cfg",
    "d:/config/language.cfg",
    "d:/hunkusage.dat",
    "d:/movies/legal-us-de.wma",
    "d:/movies/legal-us-en.wma",
    "d:/movies/legal-us-fr.wma",
};

const std::vector<ContentAliasObservation> kContentAliases = {
    {"d:/movies/legal-us-en.wma", "d:/movies/legal-us.wma", false,
     "A base legal-us.wma file exists, but the requested localized name has no verified title-level alias."},
    {"d:/movies/legal-us-fr.wma", "", false,
     "No French legal-us source file exists in this disc extraction."},
    {"d:/movies/legal-us-de.wma", "", false,
     "No German legal-us source file exists in this disc extraction."},
};

}  // namespace

std::string NormalizeGuestPath(std::string_view path) {
  const std::string fixed = FixSeparatorsAndLower(path);
  if (fixed.empty()) {
    return fixed;
  }

  const bool rooted = fixed.front() == '/';
  std::vector<std::string> parts;
  for (const auto& part : Split(fixed)) {
    if (part.empty() || part == ".") {
      continue;
    }
    if (part == "..") {
      if (!parts.empty() && !EndsWithColon(parts.back())) {
        parts.pop_back();
      }
      // This follows Xenia's guest canonicalization rule: a parent marker at
      // a device/root boundary cannot remove the device name.
      continue;
    }
    parts.push_back(part);
  }
  return Join(parts, rooted);
}

std::optional<ResolvedPath> ResolveGamePath(const MountSpec& mount,
                                            std::string_view guest_path) {
  if (mount.host_root.empty()) {
    return std::nullopt;
  }

  const std::string raw = FixSeparatorsAndLower(guest_path);
  const std::string physical_mount = NormalizeGuestPath(mount.physical_mount);

  std::string relative_raw;
  std::string selected_prefix;
  if (StartsWithComponent(raw, std::string(kGameAlias), &relative_raw)) {
    selected_prefix = std::string(kGameAlias);
  } else if (StartsWithComponent(raw, std::string(kPartitionAlias), &relative_raw)) {
    selected_prefix = std::string(kPartitionAlias);
  } else if (!physical_mount.empty() &&
             StartsWithComponent(raw, physical_mount, &relative_raw)) {
    selected_prefix = physical_mount;
  } else {
    // cache:, update:, host drive paths, and arbitrary NT paths do not point
    // at the game data device in this isolated mapping.
    return std::nullopt;
  }

  auto relative = CanonicalizeRelative(relative_raw);
  if (!relative) {
    return std::nullopt;
  }

  std::filesystem::path host_path = mount.host_root;
  if (!relative->empty()) {
    for (const auto& component : Split(*relative)) {
      host_path /= std::filesystem::path(component);
    }
  }

  ResolvedPath result;
  result.relative_path = *relative;
  result.canonical_guest_path = selected_prefix;
  if (!relative->empty()) {
    result.canonical_guest_path += '/' + *relative;
  }
  result.host_path = std::move(host_path);
  return result;
}

const std::vector<std::string>& ExpectedRootFiles() { return kRootFiles; }

const std::vector<std::string>& ExpectedConfigFiles() { return kConfigFiles; }

const std::vector<std::string>& ExpectedMediaFiles() { return kMediaFiles; }

const std::vector<std::string>& ExpectedMovieFiles() { return kMovieFiles; }

const std::vector<std::string>& ObservedMissingPaths() { return kMissingPaths; }

const std::vector<ContentAliasObservation>& ObservedContentAliases() {
  return kContentAliases;
}

}  // namespace cod3::vfs_media
