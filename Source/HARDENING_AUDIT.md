# PriFacie Hardening Audit (2026-03-10)

## Scope
- Local code hardening review for crypto, profile storage, build/link settings, and deployment artifact composition.

## Remediations Applied

### 1) Authentication comparison hardened
- Replaced direct hash vector equality with constant-time comparison.
- Files:
  - `src/crypto_utils.h`
  - `src/crypto_utils.cpp`
  - `src/profile_store.cpp`

### 2) Sensitive file/directory permissions tightened
- Profile directories now forced to owner-only permissions.
- Sensitive files (`lock.conf`, encrypted stores, engine id) are written and then permissioned owner read/write.
- Files:
  - `src/profile_store.cpp`
  - `src/credential_store.cpp`
  - `src/browser_data_store.cpp`

### 3) Master password KDF hardening with backward compatibility
- Added PBKDF2 iteration versioning in profile lock config (`iter` in `lock.conf`).
- New/updated master-password writes now use higher work factor (`600000` iterations).
- Existing profiles without `iter` continue to verify using legacy work factor (`240000`) to avoid lockout.
- Files:
  - `src/crypto_utils.h`
  - `src/crypto_utils.cpp`
  - `src/profile_store.cpp`

### 4) Web data at-rest hardening
- Removed persistent website data usage from runtime and switched to `nonPersistentDataStore` (in-memory only).
- Added purge of legacy disk artifacts in profile `data/` and `cache/`.
- Added purge of legacy persistent stores (default + prior profile-identifier store IDs).
- Result: cache/cookies/local website storage are not retained unencrypted on disk between sessions.
- Files:
  - `src/browser_window_mac.mm`

### 5) Lock-flow hardening
- Lock operation now forces encrypted vault persistence and clears runtime website data before unlock prompt.
- Lock flow drops captured TLS trust objects and loads a neutral lock page before unlock.
- Session key bytes are wiped from memory on window close.
- Files:
  - `src/browser_window_mac.mm`

### 6) Certificate visibility feature (security transparency)
- Added user-visible TLS certificate inspection for HTTPS pages:
  - trust status
  - subject/issuer
  - validity period
  - SAN DNS names
  - SHA-256 fingerprint
- Files:
  - `src/browser_window_mac.mm`

### 7) Release build hardening flags
- Static OpenSSL linking enabled.
- Release compile hardening options added (`-fstack-protector-strong`, `-D_FORTIFY_SOURCE=2`, `-O3`).
- Release linker dead-strip enabled.
- Security framework linkage added for trust/certificate APIs.
- Files:
  - `CMakeLists.txt`

### 8) Deployment dependency verification
- Final release binary has no dynamic OpenSSL dependency.
- Verified with `otool -L`.

## Deployment Artifacts
- Release build directory: `build-prod/`
- Installed runtime payload: `dist-prod/PriFacie.app`
- Archive: `dist-prod/PriFacie-macos-release-x86_64.tar.gz`

## Remaining external production tasks (outside code)
- Apple Developer ID signing (non-ad-hoc)
- Notarization
- Stapling notarization ticket
- Optional: universal (`x86_64+arm64`) build pipeline
