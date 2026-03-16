#include "credential_store.h"

#include "crypto_utils.h"

#include <cctype>
#include <filesystem>
#include <fstream>
#include <sstream>
#include <utility>

namespace fs = std::filesystem;

namespace {
void SetOwnerOnlyFilePermissions(const std::string& path) {
  std::error_code ec;
  fs::permissions(path, fs::perms::owner_read | fs::perms::owner_write, fs::perm_options::replace, ec);
}
}  // namespace

CredentialStore::CredentialStore(std::string file_path) : file_path_(std::move(file_path)) {}

std::string CredentialStore::Escape(const std::string& value) {
  static constexpr char kHex[] = "0123456789ABCDEF";
  std::string out;
  for (unsigned char c : value) {
    const bool safe = std::isalnum(c) || c == '-' || c == '_' || c == '.' || c == '~';
    if (safe) {
      out.push_back(static_cast<char>(c));
    } else {
      out.push_back('%');
      out.push_back(kHex[(c >> 4) & 0xF]);
      out.push_back(kHex[c & 0xF]);
    }
  }
  return out;
}

std::string CredentialStore::Unescape(const std::string& value) {
  std::string out;
  out.reserve(value.size());
  for (std::size_t i = 0; i < value.size(); ++i) {
    if (value[i] == '%' && i + 2 < value.size()) {
      const char hi = value[i + 1];
      const char lo = value[i + 2];
      auto nibble = [](char ch) -> int {
        if (ch >= '0' && ch <= '9') return ch - '0';
        if (ch >= 'a' && ch <= 'f') return 10 + (ch - 'a');
        if (ch >= 'A' && ch <= 'F') return 10 + (ch - 'A');
        return -1;
      };
      const int h = nibble(hi);
      const int l = nibble(lo);
      if (h >= 0 && l >= 0) {
        out.push_back(static_cast<char>((h << 4) | l));
        i += 2;
        continue;
      }
    }
    out.push_back(value[i]);
  }
  return out;
}

bool CredentialStore::Load(const std::vector<unsigned char>& key) {
  by_origin_.clear();
  if (!fs::exists(file_path_)) return true;

  std::ifstream in(file_path_);
  if (!in.is_open()) return false;

  std::string line;
  std::string nonce_hex;
  std::string tag_hex;
  std::string data_hex;

  while (std::getline(in, line)) {
    const std::size_t pos = line.find('=');
    if (pos == std::string::npos) continue;
    const std::string key_name = line.substr(0, pos);
    const std::string value = line.substr(pos + 1);
    if (key_name == "nonce") nonce_hex = value;
    if (key_name == "tag") tag_hex = value;
    if (key_name == "data") data_hex = value;
  }

  if (nonce_hex.empty() || tag_hex.empty() || data_hex.empty()) return false;

  std::vector<unsigned char> nonce;
  std::vector<unsigned char> tag;
  std::vector<unsigned char> data;
  if (!crypto::HexDecode(nonce_hex, &nonce) || !crypto::HexDecode(tag_hex, &tag) ||
      !crypto::HexDecode(data_hex, &data)) {
    return false;
  }

  std::vector<unsigned char> plaintext;
  if (!crypto::DecryptAes256Gcm(key, nonce, tag, data, &plaintext)) return false;
  std::string payload(plaintext.begin(), plaintext.end());

  std::istringstream stream(payload);
  while (std::getline(stream, line)) {
    if (line.empty()) continue;
    std::istringstream row(line);
    std::string origin;
    std::string username;
    std::string password;
    if (!std::getline(row, origin, '\t')) continue;
    if (!std::getline(row, username, '\t')) continue;
    if (!std::getline(row, password, '\t')) continue;

    SavedCredential cred;
    cred.origin = Unescape(origin);
    cred.username = Unescape(username);
    cred.password = Unescape(password);
    by_origin_[cred.origin] = cred;
  }
  return true;
}

bool CredentialStore::Save(const std::vector<unsigned char>& key) const {
  std::ostringstream payload;
  for (const auto& [_, cred] : by_origin_) {
    payload << Escape(cred.origin) << "\t" << Escape(cred.username) << "\t"
            << Escape(cred.password) << "\n";
  }
  std::string plaintext = payload.str();
  std::vector<unsigned char> plaintext_bytes(plaintext.begin(), plaintext.end());

  std::vector<unsigned char> nonce;
  std::vector<unsigned char> tag;
  std::vector<unsigned char> ciphertext;
  if (!crypto::EncryptAes256Gcm(key, plaintext_bytes, &nonce, &tag, &ciphertext)) return false;

  std::ofstream out(file_path_, std::ios::trunc);
  if (!out.is_open()) return false;
  out << "nonce=" << crypto::HexEncode(nonce) << "\n";
  out << "tag=" << crypto::HexEncode(tag) << "\n";
  out << "data=" << crypto::HexEncode(ciphertext) << "\n";
  out.close();
  SetOwnerOnlyFilePermissions(file_path_);
  return true;
}

void CredentialStore::Upsert(const SavedCredential& cred) {
  by_origin_[cred.origin] = cred;
}

std::optional<SavedCredential> CredentialStore::FindByOrigin(const std::string& origin) const {
  const auto it = by_origin_.find(origin);
  if (it == by_origin_.end()) return std::nullopt;
  return it->second;
}

std::vector<SavedCredential> CredentialStore::List() const {
  std::vector<SavedCredential> out;
  out.reserve(by_origin_.size());
  for (const auto& [_, cred] : by_origin_) out.push_back(cred);
  return out;
}
