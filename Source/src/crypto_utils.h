#pragma once

#include <cstddef>
#include <string>
#include <vector>

namespace crypto {

std::vector<unsigned char> RandomBytes(std::size_t count);
std::string HexEncode(const std::vector<unsigned char>& data);
bool HexDecode(const std::string& hex, std::vector<unsigned char>* out);
bool ConstantTimeEquals(const std::vector<unsigned char>& a,
                        const std::vector<unsigned char>& b);

bool DeriveKeyPBKDF2(const std::string& password,
                     const std::vector<unsigned char>& salt,
                     std::vector<unsigned char>* out_key);
bool DeriveKeyPBKDF2(const std::string& password,
                     const std::vector<unsigned char>& salt,
                     int iterations,
                     std::vector<unsigned char>* out_key);

bool EncryptAes256Gcm(const std::vector<unsigned char>& key,
                      const std::vector<unsigned char>& plaintext,
                      std::vector<unsigned char>* out_nonce,
                      std::vector<unsigned char>* out_tag,
                      std::vector<unsigned char>* out_ciphertext);

bool DecryptAes256Gcm(const std::vector<unsigned char>& key,
                      const std::vector<unsigned char>& nonce,
                      const std::vector<unsigned char>& tag,
                      const std::vector<unsigned char>& ciphertext,
                      std::vector<unsigned char>* out_plaintext);

}  // namespace crypto
