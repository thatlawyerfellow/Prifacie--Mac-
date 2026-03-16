#include "crypto_utils.h"

#include <openssl/evp.h>
#include <openssl/rand.h>

#include <algorithm>
#include <cstring>

namespace crypto {
namespace {

constexpr int kKeyBytes = 32;
constexpr int kSaltBytes = 16;
constexpr int kNonceBytes = 12;
constexpr int kTagBytes = 16;
constexpr int kPBKDF2Iterations = 240000;

unsigned char HexValue(char c) {
  if (c >= '0' && c <= '9') return static_cast<unsigned char>(c - '0');
  if (c >= 'a' && c <= 'f') return static_cast<unsigned char>(10 + c - 'a');
  if (c >= 'A' && c <= 'F') return static_cast<unsigned char>(10 + c - 'A');
  return 255;
}

}  // namespace

std::vector<unsigned char> RandomBytes(std::size_t count) {
  std::vector<unsigned char> out(count);
  if (count == 0) return out;
  if (RAND_bytes(out.data(), static_cast<int>(count)) != 1) {
    out.clear();
  }
  return out;
}

std::string HexEncode(const std::vector<unsigned char>& data) {
  static constexpr char kHex[] = "0123456789abcdef";
  std::string out;
  out.reserve(data.size() * 2);
  for (unsigned char b : data) {
    out.push_back(kHex[(b >> 4) & 0x0F]);
    out.push_back(kHex[b & 0x0F]);
  }
  return out;
}

bool HexDecode(const std::string& hex, std::vector<unsigned char>* out) {
  if (!out || hex.size() % 2 != 0) return false;
  std::vector<unsigned char> buffer;
  buffer.reserve(hex.size() / 2);
  for (std::size_t i = 0; i < hex.size(); i += 2) {
    unsigned char hi = HexValue(hex[i]);
    unsigned char lo = HexValue(hex[i + 1]);
    if (hi == 255 || lo == 255) return false;
    buffer.push_back(static_cast<unsigned char>((hi << 4) | lo));
  }
  *out = std::move(buffer);
  return true;
}

bool ConstantTimeEquals(const std::vector<unsigned char>& a,
                        const std::vector<unsigned char>& b) {
  const std::size_t max_len = std::max(a.size(), b.size());
  unsigned char diff = static_cast<unsigned char>(a.size() ^ b.size());
  for (std::size_t i = 0; i < max_len; ++i) {
    const unsigned char av = i < a.size() ? a[i] : 0;
    const unsigned char bv = i < b.size() ? b[i] : 0;
    diff |= static_cast<unsigned char>(av ^ bv);
  }
  return diff == 0;
}

bool DeriveKeyPBKDF2(const std::string& password,
                     const std::vector<unsigned char>& salt,
                     int iterations,
                     std::vector<unsigned char>* out_key) {
  if (!out_key || iterations < 100000 || salt.size() < static_cast<std::size_t>(kSaltBytes)) {
    return false;
  }
  std::vector<unsigned char> key(kKeyBytes);
  const int ok = PKCS5_PBKDF2_HMAC(password.c_str(),
                                   static_cast<int>(password.size()),
                                   salt.data(),
                                   static_cast<int>(salt.size()),
                                   iterations,
                                   EVP_sha256(),
                                   static_cast<int>(key.size()),
                                   key.data());
  if (ok != 1) return false;
  *out_key = std::move(key);
  return true;
}

bool DeriveKeyPBKDF2(const std::string& password,
                     const std::vector<unsigned char>& salt,
                     std::vector<unsigned char>* out_key) {
  return DeriveKeyPBKDF2(password, salt, kPBKDF2Iterations, out_key);
}

bool EncryptAes256Gcm(const std::vector<unsigned char>& key,
                      const std::vector<unsigned char>& plaintext,
                      std::vector<unsigned char>* out_nonce,
                      std::vector<unsigned char>* out_tag,
                      std::vector<unsigned char>* out_ciphertext) {
  if (!out_nonce || !out_tag || !out_ciphertext || key.size() != static_cast<std::size_t>(kKeyBytes)) {
    return false;
  }

  std::vector<unsigned char> nonce = RandomBytes(kNonceBytes);
  if (nonce.size() != static_cast<std::size_t>(kNonceBytes)) return false;

  EVP_CIPHER_CTX* ctx = EVP_CIPHER_CTX_new();
  if (!ctx) return false;

  std::vector<unsigned char> ciphertext(plaintext.size() + 16);
  int len = 0;
  int total_len = 0;
  bool ok = true;

  if (EVP_EncryptInit_ex(ctx, EVP_aes_256_gcm(), nullptr, nullptr, nullptr) != 1) ok = false;
  if (ok && EVP_CIPHER_CTX_ctrl(ctx, EVP_CTRL_GCM_SET_IVLEN, kNonceBytes, nullptr) != 1) ok = false;
  if (ok && EVP_EncryptInit_ex(ctx, nullptr, nullptr, key.data(), nonce.data()) != 1) ok = false;
  if (ok && !plaintext.empty() &&
      EVP_EncryptUpdate(ctx,
                        ciphertext.data(),
                        &len,
                        plaintext.data(),
                        static_cast<int>(plaintext.size())) != 1) {
    ok = false;
  }
  total_len = len;
  if (ok && EVP_EncryptFinal_ex(ctx, ciphertext.data() + total_len, &len) != 1) ok = false;
  total_len += len;

  std::vector<unsigned char> tag(kTagBytes);
  if (ok && EVP_CIPHER_CTX_ctrl(ctx, EVP_CTRL_GCM_GET_TAG, kTagBytes, tag.data()) != 1) ok = false;

  EVP_CIPHER_CTX_free(ctx);

  if (!ok) return false;
  ciphertext.resize(static_cast<std::size_t>(total_len));
  *out_nonce = std::move(nonce);
  *out_tag = std::move(tag);
  *out_ciphertext = std::move(ciphertext);
  return true;
}

bool DecryptAes256Gcm(const std::vector<unsigned char>& key,
                      const std::vector<unsigned char>& nonce,
                      const std::vector<unsigned char>& tag,
                      const std::vector<unsigned char>& ciphertext,
                      std::vector<unsigned char>* out_plaintext) {
  if (!out_plaintext ||
      key.size() != static_cast<std::size_t>(kKeyBytes) ||
      nonce.size() != static_cast<std::size_t>(kNonceBytes) ||
      tag.size() != static_cast<std::size_t>(kTagBytes)) {
    return false;
  }

  EVP_CIPHER_CTX* ctx = EVP_CIPHER_CTX_new();
  if (!ctx) return false;

  std::vector<unsigned char> plaintext(ciphertext.size() + 16);
  int len = 0;
  int total_len = 0;
  bool ok = true;

  if (EVP_DecryptInit_ex(ctx, EVP_aes_256_gcm(), nullptr, nullptr, nullptr) != 1) ok = false;
  if (ok && EVP_CIPHER_CTX_ctrl(ctx, EVP_CTRL_GCM_SET_IVLEN, kNonceBytes, nullptr) != 1) ok = false;
  if (ok && EVP_DecryptInit_ex(ctx, nullptr, nullptr, key.data(), nonce.data()) != 1) ok = false;
  if (ok && !ciphertext.empty() &&
      EVP_DecryptUpdate(ctx,
                        plaintext.data(),
                        &len,
                        ciphertext.data(),
                        static_cast<int>(ciphertext.size())) != 1) {
    ok = false;
  }
  total_len = len;
  if (ok && EVP_CIPHER_CTX_ctrl(ctx, EVP_CTRL_GCM_SET_TAG, kTagBytes, const_cast<unsigned char*>(tag.data())) != 1) {
    ok = false;
  }
  if (ok && EVP_DecryptFinal_ex(ctx, plaintext.data() + total_len, &len) != 1) ok = false;
  total_len += len;

  EVP_CIPHER_CTX_free(ctx);

  if (!ok) return false;
  plaintext.resize(static_cast<std::size_t>(total_len));
  *out_plaintext = std::move(plaintext);
  return true;
}

}  // namespace crypto
