#pragma once

#include <cstdint>
#include <string>
#include <vector>

struct BookmarkEntry {
  std::string url;
  std::string title;
  std::int64_t created_at = 0;
};

struct HistoryEntry {
  std::string url;
  std::string title;
  std::int64_t visited_at = 0;
};

class BrowserDataStore {
 public:
  explicit BrowserDataStore(std::string file_path);

  bool Load(const std::vector<unsigned char>& key);
  bool Save(const std::vector<unsigned char>& key) const;

  const std::vector<BookmarkEntry>& Bookmarks() const { return bookmarks_; }
  const std::vector<HistoryEntry>& History() const { return history_; }
  const std::string& Notes() const { return notes_; }

  void SetNotes(std::string notes);

  bool IsBookmarked(const std::string& url) const;
  void AddBookmark(const std::string& url, const std::string& title, std::int64_t created_at);
  void RemoveBookmark(const std::string& url);
  void ClearBookmarks();

  void AddHistory(const std::string& url, const std::string& title, std::int64_t visited_at);
  void ClearHistory();

 private:
  std::string file_path_;
  std::vector<BookmarkEntry> bookmarks_;
  std::vector<HistoryEntry> history_;
  std::string notes_;

  static std::string Escape(const std::string& value);
  static std::string Unescape(const std::string& value);
};
