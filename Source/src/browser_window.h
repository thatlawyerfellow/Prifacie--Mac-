#pragma once

#include <string>
#include <vector>

class ProfileStore;

int RunBrowserApp(ProfileStore* profile_store,
                  const std::string& profile_name,
                  const std::vector<unsigned char>& session_key);
