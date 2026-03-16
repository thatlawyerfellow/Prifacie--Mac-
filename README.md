# PriFacie (macOS, C++/Objective-C++)

A privacy-focused macOS browser with a native Cocoa UI and pluggable engine adapter architecture.

## Stack

- Engine adapter: runtime-selectable backend (`WebKit` default, `Gecko` stub path)
- Current full-feature backend: `WKWebView` compatibility layer
- UI: `Cocoa/AppKit` (no Qt)
- Language: `C++17 + Objective-C++`
- Crypto: `OpenSSL` (`AES-256-GCM`, `PBKDF2-HMAC-SHA256`)
- Icon theme source: SF Symbols (macOS) + Font Awesome Free fallback
- App icon source: `favicon.ico` (bundled and converted to `.icns` for macOS)

## Features

- Profile isolation (encrypted per-profile vault + ephemeral in-memory website session data)
- Master password lock per profile
- Encrypted vault tied to master password for saved credentials, bookmarks, browsing history, and rough-pad notes
- Toolbar actions for common browser workflows: back/forward/reload/home, bookmark current page, bookmarks menu, history menu, find in page, zoom in/out/reset
- Downloads manager tab with per-download controls (start, pause, resume, refresh), auto-capture of downloadable links, and folder selection
- Manual "Download from URL" flow for direct HTTP/HTTPS links
- Native tabbed browsing (macOS window tabs)
- Icon-based toolbar controls with robust fallback (system symbols first, Font Awesome fallback)
- Bottom status bar for current profile/page + zoom/load state
- Standard keyboard shortcuts: Ctrl+T (new tab), Ctrl+N (new window), Ctrl+Shift+C (view site certificate), Cmd+L, Cmd+R, Cmd+J (downloads manager tab), Cmd+F, Cmd+D, Cmd+B, Cmd+Y, Cmd+[ / Cmd+], Cmd+Left/Right, Cmd+Plus/Minus/0, Cmd+N, Cmd+T, Cmd+W, Cmd+P, Cmd+Shift+L, Cmd+Shift+N, Cmd+Shift+D (dark mode)
- Privacy controls: HTTPS-only mode, tracker-domain blocking via engine content rules, third-party cookie blocking, JavaScript enable/disable, clear browsing data now/on exit
- Site certificate inspection: view TLS trust status, issuer/subject, validity window, SAN, and SHA-256 fingerprint for HTTPS pages
- Hardened web-data policy: website data store is in-memory only (ephemeral), with legacy on-disk web artifacts purged
- Dark mode toggle (black browser chrome + white text/icons)
- Clickable profile menu in toolbar with permanent profile deletion (password-confirmed erase)
- Full macOS menu bar with `File` options (new tab/window, open location, open file, close window)
- `Developer` menu and bottom dev panel (console capture, JS execution, page source snapshot, website data summary)
- About dialog: `PriFacie v0.1 (c) Ajay Kumar 2026 All Rights Reserved`
- Customizable home page (set current page, set URL, reset default)
- Search engine selector (DuckDuckGo, Google, Brave Search, Bing)
- Bookmark import/export (`.html`, Netscape bookmark format)
- Toggleable right-side rough pad (notes panel) with drag-to-resize, clear, load-from-text, and save-to-text actions

## Build (macOS)

Requirements:

- Apple Clang (Xcode CLT or Xcode)
- CMake 3.16+
- OpenSSL 3 (Homebrew is fine)
- Font Awesome Free icon font (open source)

```bash
brew install cmake ninja openssl@3
brew install --cask font-fontawesome
cmake -S . -B build-mac -G Ninja
cmake --build build-mac -j
```

Run:

```bash
open ./build-mac/PriFacie.app
open ./build-mac/PriFacie.app --args --profile work
# Optional backend selection (default is WebKit)
PRIFACIE_ENGINE_BACKEND=webkit open ./build-mac/PriFacie.app
PRIFACIE_ENGINE_BACKEND=gecko open ./build-mac/PriFacie.app
```

## Release Build

```bash
cmake -S . -B build-final -G Ninja -DCMAKE_BUILD_TYPE=Release
cmake --build build-final -j
cmake --install build-final --prefix dist
codesign --force --deep --sign - --timestamp=none dist/PriFacie.app
```

Verify linked dependencies:

```bash
otool -L build-final/PriFacie.app/Contents/MacOS/PriFacie
```

## Notes

- This is a native macOS implementation and does not depend on GTK/WebKitGTK.
- On first launch of a profile, the app prompts for a master password setup.
