#include "browser_data_store.h"

#include <algorithm>
#include <cctype>
#include <filesystem>
#include <fstream>
#include <sstream>

#include "crypto_utils.h"

namespace fs = std::filesystem;

namespace {

constexpr std::size_t kMaxHistoryEntries = 5000;

void SetOwnerOnlyFilePermissions(const std::string& path) {
  std::error_code ec;
  fs::permissions(path, fs::perms::owner_read | fs::perms::owner_write, fs::perm_options::replace, ec);
}

bool ParseI64(const std::string& text, std::int64_t* out_value) {
  if (!out_value || text.empty()) return false;
  try {
    *out_value = std::stoll(text);
    return true;
  } catch (...) {
    return false;
  }
}

}  // namespace

BrowserDataStore::BrowserDataStore(std::string file_path) : file_path_(std::move(file_path)) {}

std::string BrowserDataStore::Escape(const std::string& value) {
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

std::string BrowserDataStore::Unescape(const std::string& value) {
  std::string out;
  out.reserve(value.size());
  for (std::size_t i = 0; i < value.size(); ++i) {
    if (value[i] == '%' && i + 2 < value.size()) {
      auto nibble = [](char ch) -> int {
        if (ch >= '0' && ch <= '9') return ch - '0';
        if (ch >= 'a' && ch <= 'f') return 10 + (ch - 'a');
        if (ch >= 'A' && ch <= 'F') return 10 + (ch - 'A');
        return -1;
      };
      const int hi = nibble(value[i + 1]);
      const int lo = nibble(value[i + 2]);
      if (hi >= 0 && lo >= 0) {
        out.push_back(static_cast<char>((hi << 4) | lo));
        i += 2;
        continue;
      }
    }
    out.push_back(value[i]);
  }
  return out;
}

bool BrowserDataStore::Load(const std::vector<unsigned char>& key) {
  bookmarks_.clear();
  history_.clear();
  notes_.clear();

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
  std::vector<unsigned char> ciphertext;
  if (!crypto::HexDecode(nonce_hex, &nonce) || !crypto::HexDecode(tag_hex, &tag) ||
      !crypto::HexDecode(data_hex, &ciphertext)) {
    return false;
  }

  std::vector<unsigned char> plaintext;
  if (!crypto::DecryptAes256Gcm(key, nonce, tag, ciphertext, &plaintext)) return false;
  std::string payload(plaintext.begin(), plaintext.end());

  std::istringstream stream(payload);
  while (std::getline(stream, line)) {
    if (line.size() < 2 || line[1] != '\t') continue;
    const char type = line[0];
    std::istringstream row(line.substr(2));
    std::string f1;
    std::string f2;
    std::string f3;
    if (type == 'N') {
      notes_ = Unescape(line.substr(2));
      continue;
    }

    if (!std::getline(row, f1, '\t')) continue;
    if (!std::getline(row, f2, '\t')) continue;
    if (!std::getline(row, f3, '\t')) continue;

    std::int64_t timestamp = 0;
    if (!ParseI64(f3, &timestamp)) continue;

    if (type == 'B') {
      BookmarkEntry entry;
      entry.url = Unescape(f1);
      entry.title = Unescape(f2);
      entry.created_at = timestamp;
      if (!entry.url.empty()) bookmarks_.push_back(std::move(entry));
    } else if (type == 'H') {
      HistoryEntry entry;
      entry.url = Unescape(f1);
      entry.title = Unescape(f2);
      entry.visited_at = timestamp;
      if (!entry.url.empty()) history_.push_back(std::move(entry));
    }
  }
  return true;
}

bool BrowserDataStore::Save(const std::vector<unsigned char>& key) const {
  std::ostringstream payload;
  for (const auto& b : bookmarks_) {
    payload << "B\t" << Escape(b.url) << "\t" << Escape(b.title) << "\t" << b.created_at << "\n";
  }
  for (const auto& h : history_) {
    payload << "H\t" << Escape(h.url) << "\t" << Escape(h.title) << "\t" << h.visited_at << "\n";
  }
  payload << "N\t" << Escape(notes_) << "\n";

  const std::string plain = payload.str();
  std::vector<unsigned char> plain_bytes(plain.begin(), plain.end());

  std::vector<unsigned char> nonce;
  std::vector<unsigned char> tag;
  std::vector<unsigned char> ciphertext;
  if (!crypto::EncryptAes256Gcm(key, plain_bytes, &nonce, &tag, &ciphertext)) return false;

  std::ofstream out(file_path_, std::ios::trunc);
  if (!out.is_open()) return false;
  out << "nonce=" << crypto::HexEncode(nonce) << "\n";
  out << "tag=" << crypto::HexEncode(tag) << "\n";
  out << "data=" << crypto::HexEncode(ciphertext) << "\n";
  out.close();
  SetOwnerOnlyFilePermissions(file_path_);
  return true;
}

void BrowserDataStore::SetNotes(std::string notes) {
  notes_ = std::move(notes);
}

bool BrowserDataStore::IsBookmarked(const std::string& url) const {
  for (const auto& b : bookmarks_) {
    if (b.url == url) return true;
  }
  return false;
}

void BrowserDataStore::AddBookmark(const std::string& url,
                                   const std::string& title,
                                   std::int64_t created_at) {
  if (url.empty()) return;
  for (auto& b : bookmarks_) {
    if (b.url == url) {
      b.title = title;
      return;
    }
  }
  bookmarks_.push_back({url, title, created_at});
}

void BrowserDataStore::RemoveBookmark(const std::string& url) {
  bookmarks_.erase(
      std::remove_if(bookmarks_.begin(), bookmarks_.end(),
                     [&](const BookmarkEntry& b) { return b.url == url; }),
      bookmarks_.end());
}

void BrowserDataStore::ClearBookmarks() {
  bookmarks_.clear();
}

void BrowserDataStore::AddHistory(const std::string& url,
                                  const std::string& title,
                                  std::int64_t visited_at) {
  if (url.empty()) return;

  if (!history_.empty() && history_.back().url == url) {
    history_.back().title = title;
    history_.back().visited_at = visited_at;
    return;
  }

  history_.push_back({url, title, visited_at});
  if (history_.size() > kMaxHistoryEntries) {
    const std::size_t to_remove = history_.size() - kMaxHistoryEntries;
    history_.erase(history_.begin(), history_.begin() + static_cast<std::ptrdiff_t>(to_remove));
  }
}

void BrowserDataStore::ClearHistory() {
  history_.clear();
}
