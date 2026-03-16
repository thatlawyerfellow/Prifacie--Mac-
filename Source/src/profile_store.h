#pragma once

#include <string>
#include <vector>

struct BrowserSettings {
  bool https_only = true;
  bool block_trackers = true;
  bool block_third_party_cookies = false;
  bool javascript_enabled = true;
  bool clear_data_on_exit = false;
  bool dark_mode = false;
  std::string search_engine = "https://duckduckgo.com/?q=";
  std::string home_page = "https://duckduckgo.com";
  std::string download_folder;
};

class ProfileStore {
 public:
  explicit ProfileStore(const std::string& app_name = "PriFacieBrowser");

  bool Init();
  std::vector<std::string> ListProfiles() const;
  bool CreateProfile(const std::string& profile);
  bool DeleteProfile(const std::string& profile);
  bool ProfileExists(const std::string& profile) const;

  std::string ProfilePath(const std::string& profile) const;
  std::string CredentialsPath(const std::string& profile) const;
  std::string DataPath(const std::string& profile) const;
  std::string CachePath(const std::string& profile) const;
  std::string BlocklistPath(const std::string& profile) const;

  bool IsMasterPasswordSet(const std::string& profile) const;
  bool SetMasterPassword(const std::string& profile, const std::string& password);
  bool VerifyMasterPassword(const std::string& profile, const std::string& password) const;
  bool DeriveSessionKey(const std::string& profile,
                        const std::string& password,
                        std::vector<unsigned char>* out_key) const;
  bool GetOrCreateEngineDataStoreId(const std::string& profile, std::string* out_uuid) const;

  BrowserSettings LoadSettings(const std::string& profile) const;
  bool SaveSettings(const std::string& profile, const BrowserSettings& settings) const;

 private:
  std::string base_path_;
  std::string profiles_path_;

  static bool IsValidProfileName(const std::string& profile);
  static bool IsValidUuid(const std::string& uuid);
  static std::string GenerateUuidV4();
  static bool ParseBool(const std::string& value, bool fallback);
};
