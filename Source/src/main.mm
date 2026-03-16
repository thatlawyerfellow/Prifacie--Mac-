#import <Cocoa/Cocoa.h>

#include <algorithm>
#include <cctype>
#include <string>
#include <vector>

#include "browser_window.h"
#include "profile_store.h"

namespace {

std::string ToStdString(NSString* value) {
  if (!value) return {};
  const char* c = [value UTF8String];
  return c ? std::string(c) : std::string();
}

NSString* ToNSString(const std::string& value) {
  return [[NSString alloc] initWithBytes:value.data() length:value.size() encoding:NSUTF8StringEncoding];
}

std::string TrimWhitespace(std::string value) {
  auto is_space = [](unsigned char c) { return std::isspace(c) != 0; };
  while (!value.empty() && is_space(static_cast<unsigned char>(value.front()))) value.erase(value.begin());
  while (!value.empty() && is_space(static_cast<unsigned char>(value.back()))) value.pop_back();
  return value;
}

NSImage* LoadPriFacieIcon() {
  static NSImage* cached_icon = nil;
  static dispatch_once_t once_token;
  dispatch_once(&once_token, ^{
    NSMutableArray<NSString*>* candidates = [[NSMutableArray alloc] init];
    NSBundle* bundle = [NSBundle mainBundle];

    NSArray<NSArray<NSString*>*>* bundle_resources = @[
      @[ @"PriFacie", @"icns" ],
      @[ @"favicon", @"ico" ],
      @[ @"favicon", @"png" ],
    ];
    for (NSArray<NSString*>* resource in bundle_resources) {
      NSString* path = [bundle pathForResource:resource[0] ofType:resource[1]];
      if (path.length > 0) [candidates addObject:path];
    }

    NSString* exec_path = bundle.executablePath;
    if (exec_path.length == 0) {
      NSArray<NSString*>* args = [NSProcessInfo processInfo].arguments;
      if (args.count > 0) exec_path = args.firstObject;
    }
    if (exec_path.length > 0) {
      NSString* exec_dir = [exec_path stringByDeletingLastPathComponent];
      [candidates addObject:[exec_dir stringByAppendingPathComponent:@"favicon.ico"]];
      [candidates addObject:[exec_dir stringByAppendingPathComponent:@"../Resources/favicon.ico"]];
      [candidates addObject:[exec_dir stringByAppendingPathComponent:@"../Resources/PriFacie.icns"]];
    }

    NSString* cwd = [NSFileManager defaultManager].currentDirectoryPath;
    if (cwd.length > 0) {
      [candidates addObject:[cwd stringByAppendingPathComponent:@"favicon.ico"]];
    }

    for (NSString* path in candidates) {
      if (path.length == 0) continue;
      NSImage* icon = [[NSImage alloc] initWithContentsOfFile:path];
      if (icon) {
        cached_icon = icon;
        break;
      }
    }
  });
  return cached_icon;
}

void ApplyPriFacieIcon() {
  NSImage* icon = LoadPriFacieIcon();
  if (icon) [NSApp setApplicationIconImage:icon];
}

void StyleAlert(NSAlert* alert) {
  if (!alert) return;
  NSImage* icon = LoadPriFacieIcon();
  if (icon) alert.icon = icon;
}

void ShowError(NSString* title, NSString* message) {
  NSAlert* alert = [[NSAlert alloc] init];
  StyleAlert(alert);
  alert.alertStyle = NSAlertStyleCritical;
  alert.messageText = title ? title : @"Error";
  alert.informativeText = message ? message : @"";
  [alert addButtonWithTitle:@"OK"];
  [alert runModal];
}

bool PromptText(NSString* title,
                NSString* message,
                NSString* placeholder,
                bool secure,
                std::string* out_text) {
  if (!out_text) return false;

  NSAlert* alert = [[NSAlert alloc] init];
  StyleAlert(alert);
  alert.alertStyle = NSAlertStyleInformational;
  alert.messageText = title ? title : @"Input";
  alert.informativeText = message ? message : @"";
  [alert addButtonWithTitle:@"OK"];
  [alert addButtonWithTitle:@"Cancel"];

  NSControl* field = secure ? [[NSSecureTextField alloc] initWithFrame:NSMakeRect(0, 0, 420, 26)]
                            : [[NSTextField alloc] initWithFrame:NSMakeRect(0, 0, 420, 26)];
  if ([field respondsToSelector:@selector(setPlaceholderString:)]) {
    [(id)field setPlaceholderString:placeholder ? placeholder : @""];
  }
  alert.accessoryView = field;

  const NSModalResponse result = [alert runModal];
  if (result != NSAlertFirstButtonReturn) return false;

  NSString* value = @"";
  if ([field isKindOfClass:[NSTextField class]]) {
    value = [(NSTextField*)field stringValue];
  }
  *out_text = ToStdString(value);
  return !out_text->empty();
}

bool PromptProfile(const std::vector<std::string>& existing, std::string* out_profile) {
  if (!out_profile) return false;

  NSAlert* alert = [[NSAlert alloc] init];
  StyleAlert(alert);
  alert.alertStyle = NSAlertStyleInformational;
  alert.messageText = @"Welcome to PriFacie";
  alert.informativeText = @"Choose an existing profile or enter a new one.";
  [alert addButtonWithTitle:@"Continue"];
  [alert addButtonWithTitle:@"Cancel"];

  NSStackView* stack = [[NSStackView alloc] initWithFrame:NSMakeRect(0, 0, 420, 104)];
  stack.orientation = NSUserInterfaceLayoutOrientationVertical;
  stack.spacing = 8;

  NSTextField* existing_label = [NSTextField labelWithString:@"Existing profiles"];
  NSPopUpButton* picker = [[NSPopUpButton alloc] initWithFrame:NSMakeRect(0, 0, 420, 26)];
  if (existing.empty()) {
    [picker addItemWithTitle:@"default"];
  } else {
    for (const std::string& profile : existing) {
      [picker addItemWithTitle:ToNSString(profile)];
    }
  }
  [picker selectItemAtIndex:0];

  NSTextField* new_label = [NSTextField labelWithString:@"New profile name (optional)"];
  NSTextField* new_profile_field = [[NSTextField alloc] initWithFrame:NSMakeRect(0, 0, 420, 26)];
  new_profile_field.placeholderString = @"default";

  [stack addArrangedSubview:existing_label];
  [stack addArrangedSubview:picker];
  [stack addArrangedSubview:new_label];
  [stack addArrangedSubview:new_profile_field];
  alert.accessoryView = stack;

  const NSModalResponse result = [alert runModal];
  if (result != NSAlertFirstButtonReturn) return false;

  std::string new_name = TrimWhitespace(ToStdString(new_profile_field.stringValue));
  if (!new_name.empty()) {
    *out_profile = new_name;
    return true;
  }

  std::string selected = TrimWhitespace(ToStdString(picker.selectedItem.title));
  if (selected.empty()) return false;
  *out_profile = selected;
  return true;
}

}  // namespace

int main(int argc, char** argv) {
  @autoreleasepool {
    [NSApplication sharedApplication];
    ApplyPriFacieIcon();
    [NSApp setActivationPolicy:NSApplicationActivationPolicyRegular];
    [NSApp activateIgnoringOtherApps:YES];

    ProfileStore store("PriFacieBrowser");
    if (!store.Init()) {
      ShowError(@"Startup Error", @"Unable to initialize profile storage.");
      return 1;
    }

    std::string profile_name;
    for (int i = 1; i < argc; ++i) {
      const std::string arg = argv[i];
      if (arg == "--profile" && i + 1 < argc) {
        profile_name = argv[++i];
      }
    }

    auto profiles = store.ListProfiles();
    std::sort(profiles.begin(), profiles.end());
    if (profiles.empty()) {
      store.CreateProfile("default");
      profiles.push_back("default");
    }

    if (profile_name.empty()) {
      if (!PromptProfile(profiles, &profile_name)) return 0;
    }

    if (!store.ProfileExists(profile_name)) {
      if (!store.CreateProfile(profile_name)) {
        ShowError(@"Profile Error", @"Failed to create selected profile.");
        return 1;
      }
    }

    if (!store.IsMasterPasswordSet(profile_name)) {
      std::string first;
      std::string second;
      if (!PromptText(@"Set Master Password",
                      @"Create a profile lock password (min 8 characters).",
                      @"Master password", true, &first) ||
          !PromptText(@"Confirm Master Password", @"Re-enter password.", @"Master password", true,
                      &second)) {
        return 0;
      }
      if (first.size() < 8 || first != second || !store.SetMasterPassword(profile_name, first)) {
        ShowError(@"Password Error",
                  @"Failed to set password. Ensure both entries match and length is at least 8.");
        return 1;
      }
    }

    std::vector<unsigned char> session_key;
    bool unlocked = false;
    for (int attempt = 0; attempt < 3; ++attempt) {
      std::string entered;
      if (!PromptText(@"Unlock Profile",
                      [NSString stringWithFormat:@"Profile: %s\nEnter master password.", profile_name.c_str()],
                      @"Master password", true, &entered)) {
        break;
      }
      if (store.VerifyMasterPassword(profile_name, entered) &&
          store.DeriveSessionKey(profile_name, entered, &session_key)) {
        unlocked = true;
        break;
      }
      ShowError(@"Wrong Password", @"Master password did not match.");
    }

    if (!unlocked) return 1;

    return RunBrowserApp(&store, profile_name, session_key);
  }
}
