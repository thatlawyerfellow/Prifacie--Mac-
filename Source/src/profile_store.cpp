#include "profile_store.h"

#include "crypto_utils.h"

#include <cstdlib>
#include <filesystem>
#include <fstream>
#include <iomanip>
#include <sstream>
#include <unordered_map>

namespace fs = std::filesystem;

namespace {
constexpr int kPreferredPBKDF2Iterations = 600000;
constexpr int kLegacyPBKDF2Iterations = 240000;


void SetOwnerOnlyFilePermissions(const std::string& path) {
  std::error_code ec;
  fs::permissions(path, fs::perms::owner_read | fs::perms::owner_write, fs::perm_options::replace, ec);
}

void SetOwnerOnlyDirPermissions(const std::string& path) {
  std::error_code ec;
  fs::permissions(path, fs::perms::owner_all, fs::perm_options::replace, ec);
}

std::unordered_map<std::string, std::string> ReadKvFile(const std::string& path) {
  std::unordered_map<std::string, std::string> out;
  std::ifstream in(path);
  if (!in.is_open()) return out;

  std::string line;
  while (std::getline(in, line)) {
    if (line.empty() || line[0] == '#') continue;
    const std::size_t pos = line.find('=');
    if (pos == std::string::npos) continue;
    out[line.substr(0, pos)] = line.substr(pos + 1);
  }
  return out;
}

bool WriteKvFile(const std::string& path,
                 const std::vector<std::pair<std::string, std::string>>& entries) {
  std::ofstream out(path, std::ios::trunc);
  if (!out.is_open()) return false;
  for (const auto& [key, value] : entries) {
    out << key << "=" << value << "\n";
  }
  out.close();
  SetOwnerOnlyFilePermissions(path);
  return true;
}

std::string GetHomeDir() {
  const char* home = std::getenv("HOME");
  return home ? home : ".";
}

int ParsePBKDF2Iterations(const std::unordered_map<std::string, std::string>& kv) {
  auto it = kv.find("iter");
  if (it == kv.end()) return kLegacyPBKDF2Iterations;
  try {
    const int value = std::stoi(it->second);
    if (value >= 100000 && value <= 5000000) return value;
  } catch (...) {
  }
  return kLegacyPBKDF2Iterations;
}

bool ReadUuidFromFile(const std::string& path, std::string* out_uuid) {
  if (!out_uuid) return false;
  std::ifstream in(path);
  std::string existing;
  if (!in.is_open() || !std::getline(in, existing)) return false;
  *out_uuid = existing;
  return true;
}

}  // namespace

ProfileStore::ProfileStore(const std::string& app_name) {
  base_path_ = GetHomeDir() + "/." + app_name;
  profiles_path_ = base_path_ + "/profiles";
}

bool ProfileStore::Init() {
  try {
    fs::create_directories(base_path_);
    fs::create_directories(profiles_path_);
    SetOwnerOnlyDirPermissions(base_path_);
    SetOwnerOnlyDirPermissions(profiles_path_);
  } catch (...) {
    return false;
  }
  return true;
}

std::vector<std::string> ProfileStore::ListProfiles() const {
  std::vector<std::string> profiles;
  try {
    if (!fs::exists(profiles_path_)) return profiles;
    for (const auto& entry : fs::directory_iterator(profiles_path_)) {
      if (entry.is_directory()) {
        profiles.push_back(entry.path().filename().string());
      }
    }
  } catch (...) {
    return {};
  }
  return profiles;
}

bool ProfileStore::IsValidProfileName(const std::string& profile) {
  if (profile.empty()) return false;
  for (char c : profile) {
    const bool ok = (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') ||
                    (c >= '0' && c <= '9') || c == '_' || c == '-';
    if (!ok) return false;
  }
  return true;
}

bool ProfileStore::CreateProfile(const std::string& profile) {
  if (!IsValidProfileName(profile)) return false;
  try {
    fs::create_directories(ProfilePath(profile));
    fs::create_directories(DataPath(profile));
    fs::create_directories(CachePath(profile));
    SetOwnerOnlyDirPermissions(ProfilePath(profile));
    SetOwnerOnlyDirPermissions(DataPath(profile));
    SetOwnerOnlyDirPermissions(CachePath(profile));
  } catch (...) {
    return false;
  }
  BrowserSettings defaults;
  SaveSettings(profile, defaults);
  return true;
}

bool ProfileStore::DeleteProfile(const std::string& profile) {
  if (!IsValidProfileName(profile)) return false;
  const fs::path path = ProfilePath(profile);
  try {
    if (!fs::exists(path)) return false;
    if (!fs::is_directory(path)) return false;
    fs::remove_all(path);
  } catch (...) {
    return false;
  }
  return true;
}

bool ProfileStore::ProfileExists(const std::string& profile) const {
  try {
    return fs::exists(ProfilePath(profile)) && fs::is_directory(ProfilePath(profile));
  } catch (...) {
    return false;
  }
}

std::string ProfileStore::ProfilePath(const std::string& profile) const {
  return profiles_path_ + "/" + profile;
}

std::string ProfileStore::CredentialsPath(const std::string& profile) const {
  return ProfilePath(profile) + "/credentials.enc";
}

std::string ProfileStore::DataPath(const std::string& profile) const {
  return ProfilePath(profile) + "/data";
}

std::string ProfileStore::CachePath(const std::string& profile) const {
  return ProfilePath(profile) + "/cache";
}

std::string ProfileStore::BlocklistPath(const std::string& profile) const {
  return ProfilePath(profile) + "/trackers.txt";
}

bool ProfileStore::IsMasterPasswordSet(const std::string& profile) const {
  const auto kv = ReadKvFile(ProfilePath(profile) + "/lock.conf");
  return kv.find("salt") != kv.end() && kv.find("hash") != kv.end();
}

bool ProfileStore::SetMasterPassword(const std::string& profile, const std::string& password) {
  if (password.size() < 8) return false;
  std::vector<unsigned char> salt = crypto::RandomBytes(16);
  if (salt.size() != 16) return false;

  std::vector<unsigned char> key;
  if (!crypto::DeriveKeyPBKDF2(password, salt, kPreferredPBKDF2Iterations, &key)) return false;

  return WriteKvFile(ProfilePath(profile) + "/lock.conf",
                     {
                         {"salt", crypto::HexEncode(salt)},
                         {"iter", std::to_string(kPreferredPBKDF2Iterations)},
                         {"hash", crypto::HexEncode(key)},
                     });
}

bool ProfileStore::VerifyMasterPassword(const std::string& profile,
                                        const std::string& password) const {
  const auto kv = ReadKvFile(ProfilePath(profile) + "/lock.conf");
  auto salt_it = kv.find("salt");
  auto hash_it = kv.find("hash");
  if (salt_it == kv.end() || hash_it == kv.end()) return false;
  const int iterations = ParsePBKDF2Iterations(kv);

  std::vector<unsigned char> salt;
  if (!crypto::HexDecode(salt_it->second, &salt)) return false;
  std::vector<unsigned char> key;
  if (!crypto::DeriveKeyPBKDF2(password, salt, iterations, &key)) return false;

  std::vector<unsigned char> expected;
  if (!crypto::HexDecode(hash_it->second, &expected)) return false;
  return crypto::ConstantTimeEquals(key, expected);
}

bool ProfileStore::DeriveSessionKey(const std::string& profile,
                                    const std::string& password,
                                    std::vector<unsigned char>* out_key) const {
  if (!out_key) return false;
  const auto kv = ReadKvFile(ProfilePath(profile) + "/lock.conf");
  auto salt_it = kv.find("salt");
  if (salt_it == kv.end()) return false;
  const int iterations = ParsePBKDF2Iterations(kv);

  std::vector<unsigned char> salt;
  if (!crypto::HexDecode(salt_it->second, &salt)) return false;
  return crypto::DeriveKeyPBKDF2(password, salt, iterations, out_key);
}

bool ProfileStore::IsValidUuid(const std::string& uuid) {
  if (uuid.size() != 36) return false;
  for (std::size_t i = 0; i < uuid.size(); ++i) {
    if (i == 8 || i == 13 || i == 18 || i == 23) {
      if (uuid[i] != '-') return false;
      continue;
    }
    const bool hex = (uuid[i] >= '0' && uuid[i] <= '9') || (uuid[i] >= 'a' && uuid[i] <= 'f');
    if (!hex) return false;
  }
  return true;
}

std::string ProfileStore::GenerateUuidV4() {
  auto bytes = crypto::RandomBytes(16);
  if (bytes.size() != 16) return "";

  bytes[6] = static_cast<unsigned char>((bytes[6] & 0x0F) | 0x40);
  bytes[8] = static_cast<unsigned char>((bytes[8] & 0x3F) | 0x80);

  std::ostringstream oss;
  oss << std::hex << std::setfill('0');
  for (std::size_t i = 0; i < bytes.size(); ++i) {
    if (i == 4 || i == 6 || i == 8 || i == 10) oss << "-";
    oss << std::setw(2) << static_cast<int>(bytes[i]);
  }
  return oss.str();
}

bool ProfileStore::GetOrCreateEngineDataStoreId(const std::string& profile, std::string* out_uuid) const {
  if (!out_uuid || !ProfileExists(profile)) return false;
  const std::string path = ProfilePath(profile) + "/engine_store_id";

  {
    std::string existing;
    if (ReadUuidFromFile(path, &existing) && IsValidUuid(existing)) {
      *out_uuid = existing;
      return true;
    }
  }

  {
    const std::string legacy_path = ProfilePath(profile) + "/webkit_store_id";
    std::string legacy;
    if (ReadUuidFromFile(legacy_path, &legacy) && IsValidUuid(legacy)) {
      std::ofstream migrated(path, std::ios::trunc);
      if (migrated.is_open()) {
        migrated << legacy << "\n";
        migrated.close();
        SetOwnerOnlyFilePermissions(path);
      }
      *out_uuid = legacy;
      return true;
    }
  }

  const std::string uuid = GenerateUuidV4();
  if (!IsValidUuid(uuid)) return false;

  std::ofstream out(path, std::ios::trunc);
  if (!out.is_open()) return false;
  out << uuid << "\n";
  out.close();
  SetOwnerOnlyFilePermissions(path);
  *out_uuid = uuid;
  return true;
}

bool ProfileStore::ParseBool(const std::string& value, bool fallback) {
  if (value == "1" || value == "true" || value == "TRUE") return true;
  if (value == "0" || value == "false" || value == "FALSE") return false;
  return fallback;
}

BrowserSettings ProfileStore::LoadSettings(const std::string& profile) const {
  BrowserSettings out;
  const auto kv = ReadKvFile(ProfilePath(profile) + "/settings.conf");
  if (auto it = kv.find("https_only"); it != kv.end()) {
    out.https_only = ParseBool(it->second, out.https_only);
  }
  if (auto it = kv.find("block_trackers"); it != kv.end()) {
    out.block_trackers = ParseBool(it->second, out.block_trackers);
  }
  if (auto it = kv.find("block_third_party_cookies"); it != kv.end()) {
    out.block_third_party_cookies = ParseBool(it->second, out.block_third_party_cookies);
  }
  if (auto it = kv.find("javascript_enabled"); it != kv.end()) {
    out.javascript_enabled = ParseBool(it->second, out.javascript_enabled);
  }
  if (auto it = kv.find("clear_data_on_exit"); it != kv.end()) {
    out.clear_data_on_exit = ParseBool(it->second, out.clear_data_on_exit);
  }
  if (auto it = kv.find("dark_mode"); it != kv.end()) {
    out.dark_mode = ParseBool(it->second, out.dark_mode);
  }
  if (auto it = kv.find("search_engine"); it != kv.end() && !it->second.empty()) {
    out.search_engine = it->second;
  }
  if (auto it = kv.find("home_page"); it != kv.end() && !it->second.empty()) {
    out.home_page = it->second;
  }
  if (auto it = kv.find("download_folder"); it != kv.end()) {
    out.download_folder = it->second;
  }
  return out;
}

bool ProfileStore::SaveSettings(const std::string& profile, const BrowserSettings& settings) const {
  return WriteKvFile(ProfilePath(profile) + "/settings.conf",
                     {
                         {"https_only", settings.https_only ? "1" : "0"},
                         {"block_trackers", settings.block_trackers ? "1" : "0"},
                         {"block_third_party_cookies", settings.block_third_party_cookies ? "1" : "0"},
                         {"javascript_enabled", settings.javascript_enabled ? "1" : "0"},
                         {"clear_data_on_exit", settings.clear_data_on_exit ? "1" : "0"},
                         {"dark_mode", settings.dark_mode ? "1" : "0"},
                         {"search_engine", settings.search_engine},
                         {"home_page", settings.home_page},
                         {"download_folder", settings.download_folder},
                     });
}
