#pragma once

#include <optional>
#include <string>
#include <unordered_map>
#include <vector>

struct SavedCredential {
  std::string origin;
  std::string username;
  std::string password;
};

class CredentialStore {
 public:
  explicit CredentialStore(std::string file_path);

  bool Load(const std::vector<unsigned char>& key);
  bool Save(const std::vector<unsigned char>& key) const;
  void Upsert(const SavedCredential& cred);

  std::optional<SavedCredential> FindByOrigin(const std::string& origin) const;
  std::vector<SavedCredential> List() const;

 private:
  std::string file_path_;
  std::unordered_map<std::string, SavedCredential> by_origin_;

  static std::string Escape(const std::string& value);
  static std::string Unescape(const std::string& value);
};
