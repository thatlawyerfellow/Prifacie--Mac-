#import <Cocoa/Cocoa.h>
#import <Security/Security.h>
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>
#import <WebKit/WebKit.h>

#include "browser_window.h"

#include <algorithm>
#include <cctype>
#include <cmath>
#include <cstdio>
#include <ctime>
#include <filesystem>
#include <fstream>
#include <memory>
#include <regex>
#include <set>
#include <sstream>
#include <string>
#include <utility>
#include <vector>

#include <openssl/asn1.h>
#include <openssl/bio.h>
#include <openssl/evp.h>
#include <openssl/pem.h>
#include <openssl/sha.h>
#include <openssl/x509.h>
#include <openssl/x509v3.h>

#include "browser_data_store.h"
#include "credential_store.h"
#include "engine_adapter_mac.h"
#include "profile_store.h"

namespace {

constexpr CGFloat kNotesPanelWidth = 340.0;
constexpr CGFloat kMinZoom = 0.5;
constexpr CGFloat kMaxZoom = 3.0;
constexpr unsigned short kKeyCodeLeftArrow = 123;
constexpr unsigned short kKeyCodeRightArrow = 124;
constexpr const char* kDefaultHomePage = "https://duckduckgo.com";
constexpr const char* kAboutText = "PriFacie v0.1 (c) Ajay Kumar 2026 All Rights Reserved";
constexpr const char* kDownloadsManagerUrl = "prifacie://downloads";
constexpr const char* kDownloadsMessageHandler = "prifacie_downloads";
constexpr CGFloat kNotesPanelMinWidth = 220.0;
constexpr CGFloat kNotesPanelMaxWidth = 720.0;

NSString* ToNSString(const std::string& value) {
  NSString* converted = [[NSString alloc] initWithBytes:value.data()
                                                 length:value.size()
                                               encoding:NSUTF8StringEncoding];
  return converted ? converted : @"";
}

std::string ToStdString(NSString* value) {
  if (!value) return {};
  const char* c = [value UTF8String];
  return c ? std::string(c) : std::string();
}

std::string ToLower(std::string value) {
  std::transform(value.begin(), value.end(), value.begin(), [](unsigned char c) {
    return static_cast<char>(std::tolower(c));
  });
  return value;
}

std::vector<std::string> DefaultTrackerDomains() {
  return {
      "doubleclick.net",       "google-analytics.com", "googletagmanager.com", "googlesyndication.com",
      "facebook.net",          "facebook.com",         "connect.facebook.net", "adservice.google.com",
      "ads.twitter.com",       "analytics.twitter.com", "amazon-adsystem.com", "adnxs.com",
      "taboola.com",           "outbrain.com",         "scorecardresearch.com", "hotjar.com",
      "mixpanel.com",          "segment.com",          "branch.io",             "snapchat.com",
      "criteo.com",            "quantserve.com",       "matomo.cloud",          "appsflyer.com",
      "tracking-protection.cdn.mozilla.net",
  };
}

std::string JsEscape(const std::string& value) {
  std::string out;
  out.reserve(value.size() * 2);
  for (char c : value) {
    switch (c) {
      case '\\':
        out += "\\\\";
        break;
      case '\'':
        out += "\\'";
        break;
      case '\n':
        out += "\\n";
        break;
      case '\r':
        out += "\\r";
        break;
      case '\t':
        out += "\\t";
        break;
      default:
        out.push_back(c);
        break;
    }
  }
  return out;
}

NSString* TrimTitle(const std::string& text) {
  if (text.empty()) return @"(Untitled)";
  if (text.size() <= 70) return ToNSString(text);
  return [ToNSString(text.substr(0, 67)) stringByAppendingString:@"..."];
}

NSFont* IconFont(CGFloat size, bool solid) {
  NSArray<NSString*>* preferred_names =
      solid ? @[
          @"Font Awesome 7 Free Solid",
          @"Font Awesome 7 Free",
          @"Font Awesome 6 Free Solid",
          @"Font Awesome 6 Free",
          @"Font Awesome 5 Free Solid",
          @"Font Awesome 5 Free",
          @"FontAwesome7Free-Solid",
          @"FontAwesome7Free-Regular",
          @"FontAwesome6Free-Solid",
          @"FontAwesome6Free-Regular",
          @"FontAwesome5Free-Solid",
          @"FontAwesome5Free-Regular",
      ]
            : @[
          @"Font Awesome 7 Free Regular",
          @"Font Awesome 7 Free",
          @"Font Awesome 6 Free Regular",
          @"Font Awesome 6 Free",
          @"Font Awesome 5 Free Regular",
          @"Font Awesome 5 Free",
          @"FontAwesome7Free-Regular",
          @"FontAwesome6Free-Regular",
          @"FontAwesome5Free-Regular",
      ];
  NSFont* font = nil;
  for (NSString* name in preferred_names) {
    font = [NSFont fontWithName:name size:size];
    if (font) break;
  }
  return font;
}

NSString* IconGlyph(unichar codepoint) {
  return [NSString stringWithCharacters:&codepoint length:1];
}

NSString* SystemSymbolForCodepoint(unichar codepoint) {
  switch (codepoint) {
    case 0xF060:
      return @"chevron.left";
    case 0xF061:
      return @"chevron.right";
    case 0xF2F1:
      return @"arrow.clockwise";
    case 0xF015:
      return @"house.fill";
    case 0xF002:
      return @"arrow.right.circle.fill";
    case 0xF006:
      return @"star";
    case 0xF005:
      return @"star.fill";
    case 0xF02E:
      return @"bookmark.fill";
    case 0xF1DA:
      return @"clock.arrow.circlepath";
    case 0xF013:
      return @"gearshape.fill";
    case 0xF249:
      return @"note.text";
    case 0xF023:
      return @"lock.fill";
    case 0xF007:
      return @"person.crop.circle";
    default:
      return @"";
  }
}

NSString* FallbackSymbol(unichar codepoint) {
  switch (codepoint) {
    case 0xF060:
      return @"<";
    case 0xF061:
      return @">";
    case 0xF2F1:
      return @"R";
    case 0xF015:
      return @"H";
    case 0xF002:
      return @"G";
    case 0xF006:
      return @"*";
    case 0xF005:
      return @"*";
    case 0xF02E:
      return @"B";
    case 0xF1DA:
      return @"Y";
    case 0xF013:
      return @"T";
    case 0xF249:
      return @"N";
    case 0xF023:
      return @"L";
    case 0xF007:
      return @"P";
    default:
      return @"+";
  }
}

void SetButtonIcon(NSButton* button,
                   unichar codepoint,
                   NSString* fallback_tooltip,
                   CGFloat size,
                   bool solid) {
  NSFont* icon_font = IconFont(size, solid);
  if (@available(macOS 11.0, *)) {
    NSString* symbol_name = SystemSymbolForCodepoint(codepoint);
    if (symbol_name.length > 0) {
      NSImage* image =
          [NSImage imageWithSystemSymbolName:symbol_name accessibilityDescription:fallback_tooltip];
      if (image) {
        NSImageSymbolConfiguration* config =
            [NSImageSymbolConfiguration configurationWithPointSize:size weight:NSFontWeightSemibold];
        image = [image imageWithSymbolConfiguration:config];
        [image setTemplate:YES];
        button.image = image;
        button.imagePosition = NSImageOnly;
        if ([button respondsToSelector:@selector(setContentTintColor:)]) {
          button.contentTintColor = NSColor.labelColor;
        }
        button.attributedTitle = [[NSAttributedString alloc] initWithString:@""];
        button.title = @"";
        button.toolTip = fallback_tooltip ? fallback_tooltip : @"";
        return;
      }
    }
  }
  if (!icon_font) {
    button.image = nil;
    button.attributedTitle = [[NSAttributedString alloc] initWithString:@""];
    button.title = FallbackSymbol(codepoint);
    button.font = [NSFont monospacedSystemFontOfSize:12 weight:NSFontWeightSemibold];
    button.toolTip = fallback_tooltip ? fallback_tooltip : @"";
    return;
  }
  NSDictionary* attrs = @{
    NSFontAttributeName : icon_font,
    NSForegroundColorAttributeName : NSColor.controlTextColor
  };
  button.image = nil;
  button.imagePosition = NSNoImage;
  button.attributedTitle = [[NSAttributedString alloc] initWithString:IconGlyph(codepoint)
                                                            attributes:attrs];
  button.title = @"";
  button.toolTip = fallback_tooltip ? fallback_tooltip : @"";
}

NSButton* ToolbarButton(NSString* title, SEL action, id target) {
  NSButton* button = [NSButton buttonWithTitle:title target:target action:action];
  button.bezelStyle = NSBezelStyleTexturedRounded;
  button.font = [NSFont systemFontOfSize:12 weight:NSFontWeightMedium];
  button.translatesAutoresizingMaskIntoConstraints = NO;
  return button;
}

NSImage* LoadPriFacieIconImage() {
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

void ApplyPriFacieIconImage() {
  NSImage* icon = LoadPriFacieIconImage();
  if (icon) [NSApp setApplicationIconImage:icon];
}

void StyleAlertWithPriFacieIcon(NSAlert* alert) {
  if (!alert) return;
  NSImage* icon = LoadPriFacieIconImage();
  if (icon) alert.icon = icon;
}

void ShowAlert(NSAlertStyle style, NSString* title, NSString* message) {
  NSAlert* alert = [[NSAlert alloc] init];
  StyleAlertWithPriFacieIcon(alert);
  alert.alertStyle = style;
  alert.messageText = title ? title : @"PriFacie";
  alert.informativeText = message ? message : @"";
  [alert addButtonWithTitle:@"OK"];
  [alert runModal];
}

void ShowError(NSString* title, NSString* message) {
  ShowAlert(NSAlertStyleCritical, title, message);
}

void ShowInfo(NSString* title, NSString* message) {
  ShowAlert(NSAlertStyleInformational, title, message);
}

bool PromptSingleText(NSString* title,
                      NSString* message,
                      NSString* placeholder,
                      bool secure,
                      std::string* out_text) {
  if (!out_text) return false;

  NSAlert* alert = [[NSAlert alloc] init];
  StyleAlertWithPriFacieIcon(alert);
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

bool PromptCredential(NSString* origin, SavedCredential* out_credential) {
  if (!out_credential) return false;

  NSAlert* alert = [[NSAlert alloc] init];
  StyleAlertWithPriFacieIcon(alert);
  alert.alertStyle = NSAlertStyleInformational;
  alert.messageText = @"Save Credentials";
  alert.informativeText = [NSString stringWithFormat:@"Origin: %@", origin ? origin : @""];
  [alert addButtonWithTitle:@"Save"];
  [alert addButtonWithTitle:@"Cancel"];

  NSStackView* stack = [[NSStackView alloc] initWithFrame:NSMakeRect(0, 0, 360, 58)];
  stack.orientation = NSUserInterfaceLayoutOrientationVertical;
  stack.spacing = 8;

  NSTextField* user = [[NSTextField alloc] initWithFrame:NSMakeRect(0, 0, 360, 24)];
  user.placeholderString = @"Username";
  NSSecureTextField* pass = [[NSSecureTextField alloc] initWithFrame:NSMakeRect(0, 0, 360, 24)];
  pass.placeholderString = @"Password";
  [stack addArrangedSubview:user];
  [stack addArrangedSubview:pass];
  alert.accessoryView = stack;

  const NSModalResponse result = [alert runModal];
  if (result != NSAlertFirstButtonReturn) return false;

  const std::string username = ToStdString(user.stringValue);
  const std::string password = ToStdString(pass.stringValue);
  if (username.empty() || password.empty()) return false;

  out_credential->origin = ToStdString(origin);
  out_credential->username = username;
  out_credential->password = password;
  return true;
}

bool PromptDangerConfirm(NSString* title, NSString* message, NSString* button_title) {
  NSAlert* alert = [[NSAlert alloc] init];
  StyleAlertWithPriFacieIcon(alert);
  alert.alertStyle = NSAlertStyleCritical;
  alert.messageText = title ? title : @"Confirm";
  alert.informativeText = message ? message : @"";
  [alert addButtonWithTitle:button_title ? button_title : @"Delete"];
  [alert addButtonWithTitle:@"Cancel"];
  return [alert runModal] == NSAlertFirstButtonReturn;
}

std::string HtmlEscape(const std::string& value) {
  std::string out;
  out.reserve(value.size() * 2);
  for (char c : value) {
    switch (c) {
      case '&':
        out += "&amp;";
        break;
      case '<':
        out += "&lt;";
        break;
      case '>':
        out += "&gt;";
        break;
      case '"':
        out += "&quot;";
        break;
      case '\'':
        out += "&#39;";
        break;
      default:
        out.push_back(c);
        break;
    }
  }
  return out;
}

std::string ReplaceAll(std::string in, const std::string& from, const std::string& to) {
  if (from.empty()) return in;
  std::size_t pos = 0;
  while ((pos = in.find(from, pos)) != std::string::npos) {
    in.replace(pos, from.size(), to);
    pos += to.size();
  }
  return in;
}

std::string HtmlUnescape(std::string value) {
  value = ReplaceAll(std::move(value), "&quot;", "\"");
  value = ReplaceAll(std::move(value), "&#39;", "'");
  value = ReplaceAll(std::move(value), "&gt;", ">");
  value = ReplaceAll(std::move(value), "&lt;", "<");
  value = ReplaceAll(std::move(value), "&amp;", "&");
  return value;
}

std::string StripHtmlTags(const std::string& value) {
  std::string out;
  out.reserve(value.size());
  bool in_tag = false;
  for (char c : value) {
    if (c == '<') {
      in_tag = true;
      continue;
    }
    if (c == '>') {
      in_tag = false;
      continue;
    }
    if (!in_tag) out.push_back(c);
  }
  return out;
}

std::string BuildSearchUrl(const BrowserSettings& settings, NSString* query) {
  NSString* encoded = [query stringByAddingPercentEncodingWithAllowedCharacters:
                                 [NSCharacterSet URLQueryAllowedCharacterSet]];
  return settings.search_engine + ToStdString(encoded ? encoded : @"");
}

std::string ResolveNavigationUrl(const BrowserSettings& settings, NSString* input) {
  std::string uri = ToStdString(input ? input : @"");
  if (uri.empty()) return uri;
  if (uri.rfind("http://", 0) != 0 && uri.rfind("https://", 0) != 0 &&
      uri.rfind("file://", 0) != 0) {
    if (uri.find(' ') == std::string::npos && uri.find('.') != std::string::npos) {
      uri = "https://" + uri;
    } else {
      uri = BuildSearchUrl(settings, input);
    }
  }
  return uri;
}

std::int64_t NowEpochSeconds() {
  return static_cast<std::int64_t>(std::time(nullptr));
}

bool IsLikelyDownloadUrl(NSURL* url) {
  if (!url) return false;
  NSString* ext = url.pathExtension.lowercaseString ? url.pathExtension.lowercaseString : @"";
  if (ext.length == 0) return false;
  static NSSet<NSString*>* download_ext = nil;
  static dispatch_once_t once_token;
  dispatch_once(&once_token, ^{
    download_ext = [NSSet setWithArray:@[
      @"zip", @"7z", @"rar", @"tar", @"gz", @"bz2", @"xz", @"dmg", @"pkg", @"iso",
      @"exe", @"msi", @"deb", @"rpm", @"apk", @"ipa", @"bin",
      @"csv", @"tsv", @"json", @"xml", @"txt", @"pdf",
      @"doc", @"docx", @"xls", @"xlsx", @"ppt", @"pptx"
    ]];
  });
  return [download_ext containsObject:ext];
}

NSString* FormatByteCount(std::int64_t bytes) {
  if (bytes < 0) return @"--";
  static const char* kUnits[] = {"B", "KB", "MB", "GB", "TB"};
  double value = static_cast<double>(bytes);
  std::size_t unit_index = 0;
  while (value >= 1024.0 && unit_index < 4) {
    value /= 1024.0;
    ++unit_index;
  }
  return [NSString stringWithFormat:@"%.1f %s", value, kUnits[unit_index]];
}

std::vector<unsigned char> ToByteVector(NSData* data) {
  if (!data || data.length == 0) return {};
  const unsigned char* ptr = static_cast<const unsigned char*>(data.bytes);
  return std::vector<unsigned char>(ptr, ptr + data.length);
}

NSData* ToNSData(const std::vector<unsigned char>& bytes) {
  if (bytes.empty()) return nil;
  return [NSData dataWithBytes:bytes.data() length:bytes.size()];
}

struct DownloadItem {
  int id = 0;
  std::string url;
  std::string suggested_name;
  std::string status = "queued";  // queued/downloading/paused/completed/failed/canceled
  std::string saved_path;
  std::string error_text;
  std::int64_t total_bytes = -1;
  std::int64_t received_bytes = 0;
  std::vector<unsigned char> resume_data;
  std::int64_t created_at = 0;
};

void SecureWipe(std::vector<unsigned char>* data) {
  if (!data) return;
  std::fill(data->begin(), data->end(), 0);
  data->clear();
}

std::string HexFingerprint(const unsigned char* bytes, std::size_t len) {
  static constexpr char kHex[] = "0123456789ABCDEF";
  std::string out;
  out.reserve(len * 3);
  for (std::size_t i = 0; i < len; ++i) {
    const unsigned char b = bytes[i];
    out.push_back(kHex[(b >> 4) & 0x0F]);
    out.push_back(kHex[b & 0x0F]);
    if (i + 1 < len) out.push_back(':');
  }
  return out;
}

std::string X509NameString(X509_NAME* name) {
  if (!name) return {};
  BIO* bio = BIO_new(BIO_s_mem());
  if (!bio) return {};
  std::string out;
  if (X509_NAME_print_ex(bio, name, 0, XN_FLAG_RFC2253) >= 0) {
    char* data = nullptr;
    const long len = BIO_get_mem_data(bio, &data);
    if (len > 0 && data) out.assign(data, static_cast<std::size_t>(len));
  }
  BIO_free(bio);
  return out;
}

std::string ASN1TimeString(const ASN1_TIME* time) {
  if (!time) return {};
  BIO* bio = BIO_new(BIO_s_mem());
  if (!bio) return {};
  std::string out;
  if (ASN1_TIME_print(bio, time) == 1) {
    char* data = nullptr;
    const long len = BIO_get_mem_data(bio, &data);
    if (len > 0 && data) out.assign(data, static_cast<std::size_t>(len));
  }
  BIO_free(bio);
  return out;
}

std::string CertSerialHex(X509* cert) {
  if (!cert) return {};
  ASN1_INTEGER* serial = X509_get_serialNumber(cert);
  if (!serial) return {};
  BIGNUM* bn = ASN1_INTEGER_to_BN(serial, nullptr);
  if (!bn) return {};
  char* hex = BN_bn2hex(bn);
  std::string out = hex ? hex : "";
  OPENSSL_free(hex);
  BN_free(bn);
  return out;
}

std::string LeafSanDns(X509* cert) {
  if (!cert) return {};
  GENERAL_NAMES* names =
      static_cast<GENERAL_NAMES*>(X509_get_ext_d2i(cert, NID_subject_alt_name, nullptr, nullptr));
  if (!names) return {};

  std::vector<std::string> dns;
  const int count = sk_GENERAL_NAME_num(names);
  for (int i = 0; i < count; ++i) {
    const GENERAL_NAME* name = sk_GENERAL_NAME_value(names, i);
    if (!name || name->type != GEN_DNS || !name->d.dNSName) continue;
    const unsigned char* raw = ASN1_STRING_get0_data(name->d.dNSName);
    const int len = ASN1_STRING_length(name->d.dNSName);
    if (raw && len > 0) dns.emplace_back(reinterpret_cast<const char*>(raw), static_cast<std::size_t>(len));
  }
  GENERAL_NAMES_free(names);
  if (dns.empty()) return {};

  std::ostringstream joined;
  const std::size_t max_san = 12;
  for (std::size_t i = 0; i < dns.size() && i < max_san; ++i) {
    if (i > 0) joined << ", ";
    joined << dns[i];
  }
  if (dns.size() > max_san) joined << ", ...";
  return joined.str();
}

std::string BuildCertificateDetails(SecTrustRef trust,
                                    NSString* host,
                                    bool trusted,
                                    NSString* trust_error_text) {
  std::ostringstream out;
  out << "Host: " << ToStdString(host ? host : @"") << "\n";
  out << "Trust evaluation: " << (trusted ? "Trusted" : "Not trusted") << "\n";
  if (trust_error_text.length > 0) {
    out << "Trust error: " << ToStdString(trust_error_text) << "\n";
  }
  if (!trust) {
    out << "Certificate chain not available for this page.";
    return out.str();
  }

  CFArrayRef chain = SecTrustCopyCertificateChain(trust);
  const CFIndex chain_count = chain ? CFArrayGetCount(chain) : 0;
  out << "Certificate chain length: " << static_cast<long>(chain_count) << "\n";

  SecCertificateRef leaf = nullptr;
  if (chain && chain_count > 0) {
    leaf = reinterpret_cast<SecCertificateRef>(
        const_cast<void*>(CFArrayGetValueAtIndex(chain, 0)));
  }
  if (!leaf) {
    if (chain) CFRelease(chain);
    out << "Leaf certificate unavailable.";
    return out.str();
  }

  CFDataRef leaf_data = SecCertificateCopyData(leaf);
  if (!leaf_data) {
    if (chain) CFRelease(chain);
    out << "Leaf certificate data unavailable.";
    return out.str();
  }

  const unsigned char* der = CFDataGetBytePtr(leaf_data);
  long der_len = static_cast<long>(CFDataGetLength(leaf_data));
  X509* cert = nullptr;
  if (der && der_len > 0) cert = d2i_X509(nullptr, &der, der_len);
  CFRelease(leaf_data);
  if (chain) CFRelease(chain);

  if (!cert) {
    out << "Unable to parse certificate details.";
    return out.str();
  }

  const std::string subject = X509NameString(X509_get_subject_name(cert));
  const std::string issuer = X509NameString(X509_get_issuer_name(cert));
  const std::string serial = CertSerialHex(cert);
  const std::string not_before = ASN1TimeString(X509_get0_notBefore(cert));
  const std::string not_after = ASN1TimeString(X509_get0_notAfter(cert));
  const std::string san = LeafSanDns(cert);

  unsigned char digest[SHA256_DIGEST_LENGTH];
  unsigned int digest_len = 0;
  std::string fingerprint = "(unavailable)";
  if (X509_digest(cert, EVP_sha256(), digest, &digest_len) == 1) {
    fingerprint = HexFingerprint(digest, digest_len);
  }

  X509_free(cert);

  out << "\nLeaf certificate\n";
  out << "Subject: " << subject << "\n";
  out << "Issuer: " << issuer << "\n";
  out << "Serial: " << serial << "\n";
  out << "Valid from: " << not_before << "\n";
  out << "Valid until: " << not_after << "\n";
  if (!san.empty()) out << "SAN (DNS): " << san << "\n";
  out << "SHA-256 fingerprint: " << fingerprint << "\n";
  return out.str();
}

void ShowLargeTextDialog(NSString* title, NSString* summary, NSString* details) {
  NSAlert* alert = [[NSAlert alloc] init];
  StyleAlertWithPriFacieIcon(alert);
  alert.alertStyle = NSAlertStyleInformational;
  alert.messageText = title ? title : @"Details";
  alert.informativeText = summary ? summary : @"";
  [alert addButtonWithTitle:@"OK"];
  [alert addButtonWithTitle:@"Copy"];

  NSScrollView* scroll = [[NSScrollView alloc] initWithFrame:NSMakeRect(0, 0, 560, 260)];
  scroll.hasVerticalScroller = YES;
  scroll.hasHorizontalScroller = NO;
  scroll.borderType = NSBezelBorder;

  NSTextView* text = [[NSTextView alloc] initWithFrame:NSMakeRect(0, 0, 560, 260)];
  text.editable = NO;
  text.selectable = YES;
  text.font = [NSFont monospacedSystemFontOfSize:12 weight:NSFontWeightRegular];
  text.string = details ? details : @"";
  scroll.documentView = text;
  alert.accessoryView = scroll;

  const NSModalResponse response = [alert runModal];
  if (response == NSAlertSecondButtonReturn) {
    NSPasteboard* pasteboard = [NSPasteboard generalPasteboard];
    [pasteboard clearContents];
    [pasteboard setString:(details ? details : @"") forType:NSPasteboardTypeString];
  }
}

}  // namespace

@interface PriFacieBrowserController
    : NSObject <NSWindowDelegate,
                WKNavigationDelegate,
                WKUIDelegate,
                WKScriptMessageHandler,
                NSURLSessionDelegate,
                NSURLSessionDownloadDelegate,
                NSTextFieldDelegate,
                NSTextViewDelegate> {
 @private
  ProfileStore* _profileStore;
  std::string _profileName;
  BrowserSettings _settings;
  std::vector<unsigned char> _sessionKey;
  std::unique_ptr<CredentialStore> _credentialStore;
  std::unique_ptr<BrowserDataStore> _browserData;
  std::vector<std::string> _trackerDomains;

  NSWindow* _window;
  NSView* _rootView;
  NSView* _topBar;
  PriFacieEngineAdapter* _engineAdapter;
  NSView* _engineContentView;
  WKWebView* _webView;
  NSTextField* _addressField;
  NSTextField* _securityBadge;
  NSTextField* _statusLeftLabel;
  NSTextField* _statusRightLabel;
  NSView* _statusBar;

  NSButton* _backButton;
  NSButton* _forwardButton;
  NSButton* _reloadButton;
  NSButton* _homeButton;
  NSButton* _bookmarkToggleButton;
  NSButton* _bookmarksButton;
  NSButton* _historyButton;
  NSButton* _toolsButton;
  NSButton* _notesToggleButton;
  NSButton* _profileButton;
  NSButton* _lockButton;

  NSMenu* _bookmarksMenu;
  NSMenu* _historyMenu;
  NSMenu* _toolsMenu;
  NSMenu* _profileMenu;

  NSView* _devPanel;
  NSTextView* _devTextView;
  NSTextField* _devInputField;
  NSLayoutConstraint* _devPanelHeightConstraint;
  bool _devPanelVisible;
  NSMutableString* _devLogBuffer;

  NSView* _notesPanel;
  NSView* _notesResizeHandle;
  NSTextView* _notesTextView;
  NSLayoutConstraint* _notesWidthConstraint;
  bool _notesVisible;
  CGFloat _notesPreferredWidth;
  CGFloat _notesResizeStartWidth;
  CGFloat _notesResizeStartMouseX;
  NSString* _hoveredLink;
  SecTrustRef _currentServerTrust;
  NSString* _currentServerHost;
  bool _webDataIsEphemeral;
  std::vector<DownloadItem> _downloads;
  int _nextDownloadId;
  NSURLSession* _downloadSession;
  NSMutableDictionary<NSNumber*, NSURLSessionDownloadTask*>* _activeDownloadTasks;
  NSString* _downloadTargetFolder;

  id _keyMonitor;
  bool _observingWebView;
}
- (instancetype)initWithProfileStore:(ProfileStore*)profileStore
                         profileName:(const std::string&)profileName
                          sessionKey:(const std::vector<unsigned char>&)sessionKey;
- (void)showWindow;
- (BOOL)ownsWindow:(NSWindow*)window;
- (void)onNewTab:(id)sender;
- (void)onNewWindow:(id)sender;
- (void)onOpenLocationPrompt:(id)sender;
- (void)onOpenFile:(id)sender;
- (void)onCloseWindow:(id)sender;
- (void)onAboutPriFacie:(id)sender;
- (void)onToggleDevPanel:(id)sender;
- (void)onRunDevScript:(id)sender;
- (void)onLoadPageSource:(id)sender;
- (void)onDumpWebsiteDataSummary:(id)sender;
- (void)onClearDevLogs:(id)sender;
- (void)onViewSiteCertificate:(id)sender;
- (void)onOpenDownloadsManagerTab:(id)sender;
- (void)onChooseDownloadFolder:(id)sender;
- (void)onDownloadFromUrlPrompt:(id)sender;
- (void)onLoadNotesFromFile:(id)sender;
- (void)onSaveNotesToFile:(id)sender;
@end

static NSMutableArray<PriFacieBrowserController*>* ActiveControllers() {
  static NSMutableArray<PriFacieBrowserController*>* controllers = nil;
  static dispatch_once_t once_token;
  dispatch_once(&once_token, ^{
    controllers = [[NSMutableArray alloc] init];
  });
  return controllers;
}

static PriFacieBrowserController* ActiveControllerForWindow(NSWindow* window) {
  for (PriFacieBrowserController* controller in ActiveControllers()) {
    if ([controller ownsWindow:window]) return controller;
  }
  return ActiveControllers().lastObject;
}

@implementation PriFacieBrowserController

- (instancetype)initWithProfileStore:(ProfileStore*)profileStore
                         profileName:(const std::string&)profileName
                          sessionKey:(const std::vector<unsigned char>&)sessionKey {
  self = [super init];
  if (!self) return nil;

  _profileStore = profileStore;
  _profileName = profileName;
  _settings = _profileStore->LoadSettings(_profileName);
  _sessionKey = sessionKey;
  _notesVisible = false;
  _devPanelVisible = false;
  _devLogBuffer = [[NSMutableString alloc] initWithString:@""];
  _notesResizeHandle = nil;
  _hoveredLink = @"";
  _notesPreferredWidth = kNotesPanelWidth;
  _notesResizeStartWidth = kNotesPanelWidth;
  _notesResizeStartMouseX = 0.0;
  _currentServerTrust = nullptr;
  _currentServerHost = @"";
  _webDataIsEphemeral = true;
  _downloads.clear();
  _nextDownloadId = 1;
  _downloadSession = nil;
  _activeDownloadTasks = [[NSMutableDictionary alloc] init];
  _downloadTargetFolder = @"";
  _observingWebView = false;
  _keyMonitor = nil;
  _engineAdapter = [[PriFacieEngineAdapter alloc] initWithBackend:ResolveEngineBackendFromEnvironment()];
  _engineContentView = nil;
  _webView = nil;

  _credentialStore = std::make_unique<CredentialStore>(_profileStore->CredentialsPath(_profileName));
  _credentialStore->Load(_sessionKey);

  _browserData = std::make_unique<BrowserDataStore>(_profileStore->ProfilePath(_profileName) +
                                                    "/browser_state.enc");
  _browserData->Load(_sessionKey);

  if (!_settings.download_folder.empty()) {
    _downloadTargetFolder = ToNSString(_settings.download_folder);
  }

  [self purgeLegacyDiskWebsiteArtifacts];
  [self loadTrackerDomains];
  [self buildWindow];
  [self applyPrivacySettings];
  [self loadURLString:ToNSString(_settings.home_page.empty() ? kDefaultHomePage : _settings.home_page)];
  return self;
}

- (void)purgeLegacyDiskWebsiteArtifacts {
  std::error_code ec;
  std::filesystem::remove_all(_profileStore->DataPath(_profileName), ec);
  ec.clear();
  std::filesystem::remove_all(_profileStore->CachePath(_profileName), ec);
}

- (void)loadTrackerDomains {
  std::set<std::string> domains;
  for (const auto& d : DefaultTrackerDomains()) domains.insert(ToLower(d));

  const std::string path = _profileStore->BlocklistPath(_profileName);
  if (std::filesystem::exists(path)) {
    std::ifstream in(path);
    std::string line;
    while (std::getline(in, line)) {
      line = ToLower(line);
      line.erase(std::remove_if(line.begin(), line.end(), [](unsigned char c) { return std::isspace(c); }),
                 line.end());
      if (line.empty() || line[0] == '#') continue;
      domains.insert(line);
    }
  }
  _trackerDomains.assign(domains.begin(), domains.end());
}

- (NSString*)defaultDownloadFolderPath {
  NSArray<NSString*>* folders = NSSearchPathForDirectoriesInDomains(NSDownloadsDirectory, NSUserDomainMask, YES);
  if (folders.count > 0 && folders.firstObject.length > 0) return folders.firstObject;
  return [NSHomeDirectory() stringByAppendingPathComponent:@"Downloads"];
}

- (NSString*)resolvedDownloadTargetFolderPath {
  NSString* folder = _downloadTargetFolder;
  if (folder.length == 0) folder = [self defaultDownloadFolderPath];
  BOOL is_directory = NO;
  if (![[NSFileManager defaultManager] fileExistsAtPath:folder isDirectory:&is_directory] || !is_directory) {
    [[NSFileManager defaultManager] createDirectoryAtPath:folder
                              withIntermediateDirectories:YES
                                               attributes:nil
                                                    error:nil];
  }
  _downloadTargetFolder = folder;
  return _downloadTargetFolder;
}

- (void)ensureDownloadSession {
  if (_downloadSession) return;
  NSURLSessionConfiguration* config = [NSURLSessionConfiguration defaultSessionConfiguration];
  config.requestCachePolicy = NSURLRequestReloadIgnoringLocalCacheData;
  _downloadSession = [NSURLSession sessionWithConfiguration:config
                                                   delegate:self
                                              delegateQueue:[NSOperationQueue mainQueue]];
}

- (DownloadItem*)downloadItemById:(int)downloadId {
  for (auto& item : _downloads) {
    if (item.id == downloadId) return &item;
  }
  return nullptr;
}

- (NSString*)suggestedFilenameForURL:(NSURL*)url explicit:(NSString*)explicitName {
  NSString* candidate = explicitName;
  if (candidate.length == 0 && url.lastPathComponent.length > 0) candidate = url.lastPathComponent;
  if (candidate.length == 0) candidate = @"download.bin";
  return candidate;
}

- (NSString*)uniqueDestinationPathForFilename:(NSString*)filename inFolder:(NSString*)folder {
  NSString* base = filename.length > 0 ? filename : @"download.bin";
  NSString* stem = base.stringByDeletingPathExtension;
  NSString* ext = base.pathExtension;
  NSString* candidate = [folder stringByAppendingPathComponent:base];
  int counter = 1;
  while ([[NSFileManager defaultManager] fileExistsAtPath:candidate]) {
    NSString* next = ext.length > 0 ? [NSString stringWithFormat:@"%@ (%d).%@", stem, counter, ext]
                                    : [NSString stringWithFormat:@"%@ (%d)", stem, counter];
    candidate = [folder stringByAppendingPathComponent:next];
    ++counter;
  }
  return candidate;
}

- (BOOL)isDownloadsManagerVisible {
  NSURL* url = _webView.URL;
  if (!url) return NO;
  NSString* scheme = url.scheme.lowercaseString ? url.scheme.lowercaseString : @"";
  NSString* host = url.host.lowercaseString ? url.host.lowercaseString : @"";
  return [scheme isEqualToString:@"prifacie"] && [host isEqualToString:@"downloads"];
}

- (void)loadDownloadsManagerPage {
  const bool dark = _settings.dark_mode;
  const std::string folder = ToStdString([self resolvedDownloadTargetFolderPath]);
  std::ostringstream html;
  html << "<!doctype html><html><head><meta charset='utf-8'><title>Downloads</title>"
       << "<meta name='viewport' content='width=device-width,initial-scale=1'>"
       << "<style>"
       << "body{font-family:-apple-system,BlinkMacSystemFont,'Segoe UI',sans-serif;margin:0;padding:20px;background:"
       << (dark ? "#0f1115" : "#f5f7fa") << ";color:" << (dark ? "#f2f2f2" : "#111111") << ";}"
       << ".top{display:flex;gap:8px;flex-wrap:wrap;align-items:center;margin-bottom:16px;}"
       << "button{padding:7px 11px;border-radius:8px;border:1px solid " << (dark ? "#3f4754" : "#b9c2cf")
       << ";background:" << (dark ? "#1f2530" : "#ffffff") << ";color:" << (dark ? "#f1f5f9" : "#111111")
       << ";font-weight:600;cursor:pointer;}"
       << "button:disabled{opacity:0.45;cursor:default;}"
       << "table{width:100%;border-collapse:collapse;background:" << (dark ? "#171b23" : "#ffffff")
       << ";border:1px solid " << (dark ? "#2b3340" : "#d7dde6") << ";}"
       << "th,td{padding:10px;border-bottom:1px solid " << (dark ? "#2b3340" : "#e2e8f0")
       << ";text-align:left;vertical-align:top;font-size:13px;}"
       << "th{font-size:12px;letter-spacing:0.02em;color:" << (dark ? "#b7c0cd" : "#475569") << ";}"
       << ".status{font-weight:700;text-transform:capitalize;}"
       << ".status.downloading{color:#0ea5e9;}.status.completed{color:#16a34a;}.status.failed{color:#dc2626;}"
       << ".status.paused{color:#f59e0b;}.actions{display:flex;gap:6px;flex-wrap:wrap;}"
       << ".meta{font-size:12px;color:" << (dark ? "#9aa6b2" : "#475569") << ";}"
       << "</style></head><body>";

  html << "<h2 style='margin:0 0 14px 0;'>Downloads Manager</h2>";
  html << "<div class='top'><button onclick=\"send('choose-folder',0)\">Select Target Folder</button>"
       << "<button onclick=\"send('open-folder',0)\">Open Target Folder</button>"
       << "<button onclick=\"send('refresh',0)\">Refresh</button>"
       << "<span class='meta'>Target folder: " << HtmlEscape(folder) << "</span></div>";
  html << "<div class='top'>"
       << "<input id='downloadUrl' placeholder='https://example.com/file.zip' "
       << "style='flex:1;min-width:260px;padding:8px 10px;border:1px solid " << (dark ? "#3f4754" : "#b9c2cf")
       << ";border-radius:8px;background:" << (dark ? "#11161f" : "#ffffff") << ";color:"
       << (dark ? "#f1f5f9" : "#111111") << ";'/>"
       << "<button onclick=\"send('download-url',0,document.getElementById('downloadUrl').value)\">Download URL</button>"
       << "</div>";

  html << "<table><thead><tr><th style='width:42px;'>#</th><th>File</th><th>Status</th><th>Progress</th><th>Actions</th></tr></thead><tbody>";
  if (_downloads.empty()) {
    html << "<tr><td colspan='5' class='meta'>No downloads yet.</td></tr>";
  } else {
    for (auto it = _downloads.rbegin(); it != _downloads.rend(); ++it) {
      const DownloadItem& item = *it;
      const bool can_pause = item.status == "downloading";
      const bool can_resume = item.status == "paused" || item.status == "failed" || item.status == "canceled";
      const bool can_start = item.status != "downloading";
      const std::string received = ToStdString(FormatByteCount(item.received_bytes));
      const std::string total = ToStdString(FormatByteCount(item.total_bytes));
      std::string progress = received;
      if (item.total_bytes > 0) progress += " / " + total;
      if (item.total_bytes > 0) {
        const double pct = 100.0 * static_cast<double>(item.received_bytes) /
                           static_cast<double>(item.total_bytes);
        std::ostringstream pct_text;
        pct_text << " (" << static_cast<int>(std::round(std::max(0.0, std::min(100.0, pct)))) << "%)";
        progress += pct_text.str();
      }

      html << "<tr><td>" << item.id << "</td><td>"
           << HtmlEscape(item.suggested_name.empty() ? item.url : item.suggested_name)
           << "<div class='meta'>" << HtmlEscape(item.url) << "</div>";
      if (!item.saved_path.empty()) {
        html << "<div class='meta'>Saved: " << HtmlEscape(item.saved_path) << "</div>";
      }
      if (!item.error_text.empty()) {
        html << "<div class='meta'>Error: " << HtmlEscape(item.error_text) << "</div>";
      }
      html << "</td><td><span class='status " << HtmlEscape(item.status) << "'>" << HtmlEscape(item.status)
           << "</span></td><td>" << HtmlEscape(progress) << "</td><td><div class='actions'>"
           << "<button onclick=\"send('start'," << item.id << ")\""
           << (can_start ? "" : " disabled") << ">Start</button>"
           << "<button onclick=\"send('pause'," << item.id << ")\""
           << (can_pause ? "" : " disabled") << ">Pause</button>"
           << "<button onclick=\"send('resume'," << item.id << ")\""
           << (can_resume ? "" : " disabled") << ">Resume</button>";
      if (!item.saved_path.empty()) {
        html << "<button onclick=\"send('show-item'," << item.id << ")\">Show File</button>";
      }
      html << "</div></td></tr>";
    }
  }
  html << "</tbody></table>";
  html << "<script>"
       << "function send(action,id,url){try{var bridge=(window.gecko&&window.gecko.messageHandlers)?window.gecko:window.webkit;"
       << "if(!bridge||!bridge.messageHandlers||!bridge.messageHandlers.prifacie_downloads)return;"
       << "bridge.messageHandlers.prifacie_downloads.postMessage({action:action,id:id,url:url||''});}catch(_){}}"
       << "</script></body></html>";

  [_webView loadHTMLString:ToNSString(html.str()) baseURL:[NSURL URLWithString:ToNSString(kDownloadsManagerUrl)]];
}

- (void)refreshDownloadsManagerIfVisible {
  if (![self isDownloadsManagerVisible]) return;
  [self loadDownloadsManagerPage];
}

- (void)startDownloadById:(int)downloadId {
  DownloadItem* item = [self downloadItemById:downloadId];
  if (!item) return;
  [self ensureDownloadSession];

  NSURL* source_url = [NSURL URLWithString:ToNSString(item->url)];
  if (!source_url) {
    item->status = "failed";
    item->error_text = "Invalid download URL";
    [self refreshDownloadsManagerIfVisible];
    return;
  }

  if (_settings.https_only && [source_url.scheme.lowercaseString isEqualToString:@"http"]) {
    NSURLComponents* comp = [NSURLComponents componentsWithURL:source_url resolvingAgainstBaseURL:NO];
    comp.scheme = @"https";
    if (comp.URL) source_url = comp.URL;
  }

  NSURLSessionDownloadTask* task = nil;
  if (!item->resume_data.empty()) {
    task = [_downloadSession downloadTaskWithResumeData:ToNSData(item->resume_data)];
    item->resume_data.clear();
  } else {
    NSMutableURLRequest* request = [NSMutableURLRequest requestWithURL:source_url];
    request.HTTPShouldHandleCookies = YES;
    request.timeoutInterval = 120.0;
    task = [_downloadSession downloadTaskWithRequest:request];
  }
  if (!task) {
    item->status = "failed";
    item->error_text = "Could not create download task";
    [self refreshDownloadsManagerIfVisible];
    return;
  }

  task.taskDescription = [NSString stringWithFormat:@"%d", downloadId];
  _activeDownloadTasks[@(downloadId)] = task;
  item->status = "downloading";
  item->error_text.clear();
  item->saved_path.clear();
  item->received_bytes = 0;
  item->total_bytes = -1;
  [task resume];
  [self refreshDownloadsManagerIfVisible];
}

- (void)pauseDownloadById:(int)downloadId {
  DownloadItem* item = [self downloadItemById:downloadId];
  if (!item || item->status != "downloading") return;
  NSURLSessionDownloadTask* task = _activeDownloadTasks[@(downloadId)];
  if (!task) {
    item->status = "paused";
    [self refreshDownloadsManagerIfVisible];
    return;
  }

  item->status = "paused";
  [task cancelByProducingResumeData:^(NSData* _Nullable resumeData) {
    DownloadItem* paused = [self downloadItemById:downloadId];
    if (paused) {
      paused->resume_data = ToByteVector(resumeData);
      paused->error_text.clear();
    }
    [self->_activeDownloadTasks removeObjectForKey:@(downloadId)];
    [self refreshDownloadsManagerIfVisible];
  }];
}

- (void)resumeDownloadById:(int)downloadId {
  DownloadItem* item = [self downloadItemById:downloadId];
  if (!item) return;
  [self startDownloadById:downloadId];
}

- (void)queueDownloadFromURL:(NSURL*)url suggestedFilename:(NSString*)suggestedFilename {
  if (!url) return;
  DownloadItem item;
  item.id = _nextDownloadId++;
  item.url = ToStdString(url.absoluteString ? url.absoluteString : @"");
  item.suggested_name =
      ToStdString([self suggestedFilenameForURL:url explicit:suggestedFilename ? suggestedFilename : @""]);
  item.status = "queued";
  item.created_at = NowEpochSeconds();
  _downloads.push_back(std::move(item));
  [self startDownloadById:_downloads.back().id];
}

- (BOOL)enqueueDownloadFromInputText:(NSString*)input {
  NSString* raw = input ? [input stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]]
                        : @"";
  if (raw.length == 0) {
    ShowError(@"Downloads", @"Please enter a download URL.");
    return NO;
  }

  NSURL* url = [NSURL URLWithString:raw];
  if (!url || !url.scheme.length) {
    NSString* maybe = [@"https://" stringByAppendingString:raw];
    url = [NSURL URLWithString:maybe];
  }
  if (!url || !url.scheme.length || !url.host.length) {
    ShowError(@"Downloads", @"Invalid URL. Enter a full URL like https://example.com/file.zip");
    return NO;
  }

  NSString* scheme = url.scheme.lowercaseString ? url.scheme.lowercaseString : @"";
  if (!([scheme isEqualToString:@"http"] || [scheme isEqualToString:@"https"])) {
    ShowError(@"Downloads", @"Only HTTP/HTTPS download URLs are supported.");
    return NO;
  }

  [self queueDownloadFromURL:url suggestedFilename:url.lastPathComponent];
  [self refreshDownloadsManagerIfVisible];
  return YES;
}

- (void)onNotesResizePan:(NSPanGestureRecognizer*)gesture {
  if (!_notesVisible || !_notesWidthConstraint) return;
  NSPoint location = [gesture locationInView:nil];
  if (gesture.state == NSGestureRecognizerStateBegan) {
    _notesResizeStartWidth = _notesWidthConstraint.constant;
    _notesResizeStartMouseX = location.x;
    return;
  }
  if (gesture.state == NSGestureRecognizerStateChanged) {
    const CGFloat delta = _notesResizeStartMouseX - location.x;
    const CGFloat target =
        std::max(kNotesPanelMinWidth, std::min(kNotesPanelMaxWidth, _notesResizeStartWidth + delta));
    _notesWidthConstraint.constant = target;
    _notesPreferredWidth = target;
    [_window.contentView layoutSubtreeIfNeeded];
  }
}

- (void)buildWindow {
  _window = [[NSWindow alloc] initWithContentRect:NSMakeRect(120, 120, 1440, 900)
                                         styleMask:(NSWindowStyleMaskTitled | NSWindowStyleMaskClosable |
                                                    NSWindowStyleMaskMiniaturizable |
                                                    NSWindowStyleMaskResizable)
                                           backing:NSBackingStoreBuffered
                                             defer:NO];
  _window.title = @"PriFacie";
  _window.delegate = self;
  _window.minSize = NSMakeSize(1080, 680);
  _window.tabbingMode = NSWindowTabbingModePreferred;

  _rootView = [[NSView alloc] initWithFrame:_window.contentView.bounds];
  _rootView.translatesAutoresizingMaskIntoConstraints = NO;
  _rootView.wantsLayer = YES;
  _window.contentView = _rootView;

  _topBar = [[NSView alloc] initWithFrame:NSZeroRect];
  _topBar.translatesAutoresizingMaskIntoConstraints = NO;
  _topBar.wantsLayer = YES;
  _topBar.layer.backgroundColor = [NSColor.windowBackgroundColor CGColor];
  [_rootView addSubview:_topBar];

  _backButton = ToolbarButton(@"", @selector(onBack:), self);
  _forwardButton = ToolbarButton(@"", @selector(onForward:), self);
  _reloadButton = ToolbarButton(@"", @selector(onReload:), self);
  _homeButton = ToolbarButton(@"", @selector(onHome:), self);

  _addressField = [[NSTextField alloc] initWithFrame:NSZeroRect];
  _addressField.translatesAutoresizingMaskIntoConstraints = NO;
  _addressField.placeholderString = @"Search or enter address";
  _addressField.font = [NSFont systemFontOfSize:13];
  _addressField.target = self;
  _addressField.action = @selector(onAddressCommit:);

  NSButton* goButton = ToolbarButton(@"", @selector(onGoClick:), self);
  _bookmarkToggleButton = ToolbarButton(@"", @selector(onToggleCurrentBookmark:), self);
  _bookmarksButton = ToolbarButton(@"", @selector(onBookmarksMenuButton:), self);
  _historyButton = ToolbarButton(@"", @selector(onHistoryMenuButton:), self);
  _toolsButton = ToolbarButton(@"", @selector(onToolsMenuButton:), self);
  _notesToggleButton = ToolbarButton(@"", @selector(onToggleNotesPanel:), self);
  _profileButton = ToolbarButton(@"", @selector(onProfileMenuButton:), self);
  _lockButton = ToolbarButton(@"", @selector(onLockBrowser:), self);

  SetButtonIcon(_backButton, 0xF060, @"Back", 12, true);
  SetButtonIcon(_forwardButton, 0xF061, @"Forward", 12, true);
  SetButtonIcon(_reloadButton, 0xF2F1, @"Reload", 12, true);
  SetButtonIcon(_homeButton, 0xF015, @"Home", 12, true);
  SetButtonIcon(goButton, 0xF002, @"Go", 12, true);
  SetButtonIcon(_bookmarkToggleButton, 0xF006, @"Bookmark This Page", 12, false);
  SetButtonIcon(_bookmarksButton, 0xF02E, @"Bookmarks", 12, true);
  SetButtonIcon(_historyButton, 0xF1DA, @"History", 12, true);
  SetButtonIcon(_toolsButton, 0xF013, @"Tools", 12, true);
  SetButtonIcon(_notesToggleButton, 0xF249, @"Toggle Notes", 12, true);
  SetButtonIcon(_profileButton, 0xF007, @"Profile", 12, true);
  SetButtonIcon(_lockButton, 0xF023, @"Lock Browser", 12, true);
  _profileButton.bezelStyle = NSBezelStyleRounded;
  _profileButton.font = [NSFont systemFontOfSize:11 weight:NSFontWeightSemibold];
  _profileButton.title = [NSString stringWithFormat:@" %@ ", ToNSString(_profileName)];
  _profileButton.imagePosition = NSImageLeading;

  _securityBadge = [NSTextField labelWithString:@"UNSECURE"];
  _securityBadge.translatesAutoresizingMaskIntoConstraints = NO;
  _securityBadge.font = [NSFont boldSystemFontOfSize:11];
  _securityBadge.textColor = NSColor.whiteColor;
  _securityBadge.toolTip = @"Tools -> View Site Certificate";
  _securityBadge.wantsLayer = YES;
  _securityBadge.layer.cornerRadius = 8.0;
  _securityBadge.layer.masksToBounds = YES;

  NSArray<NSView*>* topViews = @[_backButton,        _forwardButton, _reloadButton,
                                 _homeButton,        _addressField,   goButton,
                                 _securityBadge,     _bookmarkToggleButton,
                                 _bookmarksButton,   _historyButton,  _toolsButton,
                                 _notesToggleButton, _profileButton, _lockButton];
  for (NSView* v in topViews) [_topBar addSubview:v];

  _statusBar = [[NSView alloc] initWithFrame:NSZeroRect];
  _statusBar.translatesAutoresizingMaskIntoConstraints = NO;
  _statusBar.wantsLayer = YES;
  _statusBar.layer.backgroundColor = [NSColor.controlBackgroundColor CGColor];
  _statusBar.layer.borderColor = [NSColor.separatorColor CGColor];
  _statusBar.layer.borderWidth = 1.0;
  [_rootView addSubview:_statusBar];

  _statusLeftLabel = [NSTextField labelWithString:
                                      [NSString stringWithFormat:@"Profile: %s  |  Engine: %@  |  Vault: Encrypted  |  Web Data: Ephemeral",
                                                                 _profileName.c_str(),
                                                                 [_engineAdapter engineDisplayName]]];
  _statusLeftLabel.translatesAutoresizingMaskIntoConstraints = NO;
  _statusLeftLabel.textColor = NSColor.secondaryLabelColor;
  _statusLeftLabel.font = [NSFont systemFontOfSize:11 weight:NSFontWeightMedium];
  _statusLeftLabel.lineBreakMode = NSLineBreakByTruncatingMiddle;
  [_statusBar addSubview:_statusLeftLabel];

  _statusRightLabel = [NSTextField labelWithString:@"Ready"];
  _statusRightLabel.translatesAutoresizingMaskIntoConstraints = NO;
  _statusRightLabel.textColor = NSColor.labelColor;
  _statusRightLabel.font = [NSFont systemFontOfSize:11 weight:NSFontWeightSemibold];
  _statusRightLabel.lineBreakMode = NSLineBreakByTruncatingMiddle;
  _statusRightLabel.alignment = NSTextAlignmentRight;
  [_statusBar addSubview:_statusRightLabel];

  _devPanel = [[NSView alloc] initWithFrame:NSZeroRect];
  _devPanel.translatesAutoresizingMaskIntoConstraints = NO;
  _devPanel.wantsLayer = YES;
  _devPanel.layer.borderColor = [NSColor.separatorColor CGColor];
  _devPanel.layer.borderWidth = 1.0;
  [_rootView addSubview:_devPanel];

  NSTextField* devTitle = [NSTextField labelWithString:@"Developer Panel"];
  devTitle.translatesAutoresizingMaskIntoConstraints = NO;
  devTitle.font = [NSFont systemFontOfSize:12 weight:NSFontWeightSemibold];
  [_devPanel addSubview:devTitle];

  _devInputField = [[NSTextField alloc] initWithFrame:NSZeroRect];
  _devInputField.translatesAutoresizingMaskIntoConstraints = NO;
  _devInputField.placeholderString = @"Run JavaScript in active page";
  _devInputField.font = [NSFont monospacedSystemFontOfSize:12 weight:NSFontWeightRegular];
  _devInputField.target = self;
  _devInputField.action = @selector(onRunDevScript:);
  [_devPanel addSubview:_devInputField];

  NSButton* runDev = ToolbarButton(@"Run JS", @selector(onRunDevScript:), self);
  NSButton* pageSource = ToolbarButton(@"Page Source", @selector(onLoadPageSource:), self);
  NSButton* dataSummary = ToolbarButton(@"Website Data", @selector(onDumpWebsiteDataSummary:), self);
  NSButton* clearDev = ToolbarButton(@"Clear", @selector(onClearDevLogs:), self);
  [_devPanel addSubview:runDev];
  [_devPanel addSubview:pageSource];
  [_devPanel addSubview:dataSummary];
  [_devPanel addSubview:clearDev];

  NSScrollView* devScroll = [[NSScrollView alloc] initWithFrame:NSZeroRect];
  devScroll.translatesAutoresizingMaskIntoConstraints = NO;
  devScroll.hasVerticalScroller = YES;
  devScroll.hasHorizontalScroller = NO;
  devScroll.borderType = NSBezelBorder;
  [_devPanel addSubview:devScroll];

  _devTextView = [[NSTextView alloc] initWithFrame:NSMakeRect(0, 0, 100, 100)];
  _devTextView.editable = NO;
  _devTextView.selectable = YES;
  _devTextView.usesFindPanel = YES;
  _devTextView.font = [NSFont monospacedSystemFontOfSize:11 weight:NSFontWeightRegular];
  _devTextView.string = @"Developer panel initialized.";
  devScroll.documentView = _devTextView;

  _devPanel.hidden = YES;
  _devPanelHeightConstraint = [_devPanel.heightAnchor constraintEqualToConstant:0.0];
  _devPanelHeightConstraint.active = YES;

  [_engineAdapter initializeEngineWithProfileStore:_profileStore
                                        profileName:_profileName
                                           settings:_settings
                                      messageTarget:self
                                 navigationDelegate:self
                                         uiDelegate:self];
  _webView = [_engineAdapter webView];
  _engineContentView = [_engineAdapter contentView];
  _engineContentView.translatesAutoresizingMaskIntoConstraints = NO;
  _webDataIsEphemeral = _engineAdapter.webDataEphemeral;
  if (_webView) {
    [_webView.configuration.userContentController addScriptMessageHandler:self
                                                                      name:ToNSString(kDownloadsMessageHandler)];
  }

  NSView* contentRow = [[NSView alloc] initWithFrame:NSZeroRect];
  contentRow.translatesAutoresizingMaskIntoConstraints = NO;
  [_rootView addSubview:contentRow];

  NSView* webContainer = [[NSView alloc] initWithFrame:NSZeroRect];
  webContainer.translatesAutoresizingMaskIntoConstraints = NO;
  [contentRow addSubview:webContainer];
  [webContainer addSubview:_engineContentView];

  _notesPanel = [[NSView alloc] initWithFrame:NSZeroRect];
  _notesPanel.translatesAutoresizingMaskIntoConstraints = NO;
  _notesPanel.wantsLayer = YES;
  _notesPanel.layer.backgroundColor =
      [[NSColor colorWithCalibratedRed:0.97 green:0.98 blue:0.99 alpha:1.0] CGColor];
  [contentRow addSubview:_notesPanel];
  _notesResizeHandle = [[NSView alloc] initWithFrame:NSZeroRect];
  _notesResizeHandle.translatesAutoresizingMaskIntoConstraints = NO;
  _notesResizeHandle.wantsLayer = YES;
  _notesResizeHandle.layer.backgroundColor = [[NSColor colorWithCalibratedWhite:0.75 alpha:1.0] CGColor];
  [_notesPanel addSubview:_notesResizeHandle];
  NSPanGestureRecognizer* notes_resize_pan =
      [[NSPanGestureRecognizer alloc] initWithTarget:self action:@selector(onNotesResizePan:)];
  [_notesResizeHandle addGestureRecognizer:notes_resize_pan];

  NSTextField* notesTitle = [NSTextField labelWithString:@"Rough Pad"];
  notesTitle.translatesAutoresizingMaskIntoConstraints = NO;
  notesTitle.font = [NSFont systemFontOfSize:13 weight:NSFontWeightSemibold];
  [_notesPanel addSubview:notesTitle];

  NSButton* clearNotes = ToolbarButton(@"Clear", @selector(onClearNotes:), self);
  NSButton* loadNotes = ToolbarButton(@"Load", @selector(onLoadNotesFromFile:), self);
  NSButton* saveNotes = ToolbarButton(@"Save", @selector(onSaveNotesToFile:), self);
  [_notesPanel addSubview:clearNotes];
  [_notesPanel addSubview:loadNotes];
  [_notesPanel addSubview:saveNotes];

  NSScrollView* notesScroll = [[NSScrollView alloc] initWithFrame:NSZeroRect];
  notesScroll.translatesAutoresizingMaskIntoConstraints = NO;
  notesScroll.hasVerticalScroller = YES;
  notesScroll.hasHorizontalScroller = NO;
  notesScroll.borderType = NSBezelBorder;
  [_notesPanel addSubview:notesScroll];

  _notesTextView = [[NSTextView alloc] initWithFrame:NSMakeRect(0, 0, 100, 100)];
  _notesTextView.minSize = NSMakeSize(0, 0);
  _notesTextView.maxSize = NSMakeSize(CGFLOAT_MAX, CGFLOAT_MAX);
  _notesTextView.verticallyResizable = YES;
  _notesTextView.horizontallyResizable = NO;
  _notesTextView.autoresizingMask = NSViewWidthSizable;
  _notesTextView.delegate = self;
  _notesTextView.string = ToNSString(_browserData->Notes());
  notesScroll.documentView = _notesTextView;

  _notesPanel.hidden = YES;
  _notesWidthConstraint = [_notesPanel.widthAnchor constraintEqualToConstant:0.0];
  _notesWidthConstraint.active = YES;

  _bookmarksMenu = [[NSMenu alloc] initWithTitle:@"Bookmarks"];
  _historyMenu = [[NSMenu alloc] initWithTitle:@"History"];
  _toolsMenu = [[NSMenu alloc] initWithTitle:@"Tools"];
  _profileMenu = [[NSMenu alloc] initWithTitle:@"Profile"];

  [NSLayoutConstraint activateConstraints:@[
    [_topBar.topAnchor constraintEqualToAnchor:_rootView.topAnchor],
    [_topBar.leadingAnchor constraintEqualToAnchor:_rootView.leadingAnchor],
    [_topBar.trailingAnchor constraintEqualToAnchor:_rootView.trailingAnchor],
    [_topBar.heightAnchor constraintEqualToConstant:58],

    [_backButton.leadingAnchor constraintEqualToAnchor:_topBar.leadingAnchor constant:10],
    [_backButton.centerYAnchor constraintEqualToAnchor:_topBar.centerYAnchor],
    [_backButton.widthAnchor constraintEqualToConstant:34],

    [_forwardButton.leadingAnchor constraintEqualToAnchor:_backButton.trailingAnchor constant:6],
    [_forwardButton.centerYAnchor constraintEqualToAnchor:_topBar.centerYAnchor],
    [_forwardButton.widthAnchor constraintEqualToConstant:34],

    [_reloadButton.leadingAnchor constraintEqualToAnchor:_forwardButton.trailingAnchor constant:6],
    [_reloadButton.centerYAnchor constraintEqualToAnchor:_topBar.centerYAnchor],
    [_reloadButton.widthAnchor constraintEqualToConstant:34],

    [_homeButton.leadingAnchor constraintEqualToAnchor:_reloadButton.trailingAnchor constant:6],
    [_homeButton.centerYAnchor constraintEqualToAnchor:_topBar.centerYAnchor],
    [_homeButton.widthAnchor constraintEqualToConstant:34],

    [_addressField.leadingAnchor constraintEqualToAnchor:_homeButton.trailingAnchor constant:10],
    [_addressField.centerYAnchor constraintEqualToAnchor:_topBar.centerYAnchor],
    [_addressField.widthAnchor constraintGreaterThanOrEqualToConstant:340],

    [goButton.leadingAnchor constraintEqualToAnchor:_addressField.trailingAnchor constant:8],
    [goButton.centerYAnchor constraintEqualToAnchor:_topBar.centerYAnchor],
    [goButton.widthAnchor constraintEqualToConstant:34],

    [_securityBadge.leadingAnchor constraintEqualToAnchor:goButton.trailingAnchor constant:8],
    [_securityBadge.centerYAnchor constraintEqualToAnchor:_topBar.centerYAnchor],
    [_securityBadge.widthAnchor constraintGreaterThanOrEqualToConstant:74],

    [_bookmarkToggleButton.leadingAnchor constraintEqualToAnchor:_securityBadge.trailingAnchor constant:8],
    [_bookmarkToggleButton.centerYAnchor constraintEqualToAnchor:_topBar.centerYAnchor],
    [_bookmarkToggleButton.widthAnchor constraintEqualToConstant:34],

    [_bookmarksButton.leadingAnchor constraintEqualToAnchor:_bookmarkToggleButton.trailingAnchor constant:6],
    [_bookmarksButton.centerYAnchor constraintEqualToAnchor:_topBar.centerYAnchor],
    [_bookmarksButton.widthAnchor constraintEqualToConstant:34],

    [_historyButton.leadingAnchor constraintEqualToAnchor:_bookmarksButton.trailingAnchor constant:6],
    [_historyButton.centerYAnchor constraintEqualToAnchor:_topBar.centerYAnchor],
    [_historyButton.widthAnchor constraintEqualToConstant:34],

    [_toolsButton.leadingAnchor constraintEqualToAnchor:_historyButton.trailingAnchor constant:6],
    [_toolsButton.centerYAnchor constraintEqualToAnchor:_topBar.centerYAnchor],
    [_toolsButton.widthAnchor constraintEqualToConstant:34],

    [_notesToggleButton.leadingAnchor constraintEqualToAnchor:_toolsButton.trailingAnchor constant:6],
    [_notesToggleButton.centerYAnchor constraintEqualToAnchor:_topBar.centerYAnchor],
    [_notesToggleButton.widthAnchor constraintEqualToConstant:34],

    [_profileButton.leadingAnchor constraintEqualToAnchor:_notesToggleButton.trailingAnchor constant:8],
    [_profileButton.centerYAnchor constraintEqualToAnchor:_topBar.centerYAnchor],
    [_profileButton.widthAnchor constraintGreaterThanOrEqualToConstant:96],

    [_lockButton.leadingAnchor constraintEqualToAnchor:_profileButton.trailingAnchor constant:6],
    [_lockButton.trailingAnchor constraintEqualToAnchor:_topBar.trailingAnchor constant:-10],
    [_lockButton.centerYAnchor constraintEqualToAnchor:_topBar.centerYAnchor],
    [_lockButton.widthAnchor constraintEqualToConstant:34],

    [_addressField.trailingAnchor constraintLessThanOrEqualToAnchor:goButton.leadingAnchor constant:-8],

    [contentRow.topAnchor constraintEqualToAnchor:_topBar.bottomAnchor],
    [contentRow.leadingAnchor constraintEqualToAnchor:_rootView.leadingAnchor],
    [contentRow.trailingAnchor constraintEqualToAnchor:_rootView.trailingAnchor],
    [contentRow.bottomAnchor constraintEqualToAnchor:_devPanel.topAnchor constant:0],

    [_devPanel.leadingAnchor constraintEqualToAnchor:_rootView.leadingAnchor],
    [_devPanel.trailingAnchor constraintEqualToAnchor:_rootView.trailingAnchor],
    [_devPanel.bottomAnchor constraintEqualToAnchor:_statusBar.topAnchor],

    [webContainer.topAnchor constraintEqualToAnchor:contentRow.topAnchor],
    [webContainer.leadingAnchor constraintEqualToAnchor:contentRow.leadingAnchor],
    [webContainer.bottomAnchor constraintEqualToAnchor:contentRow.bottomAnchor],
    [webContainer.trailingAnchor constraintEqualToAnchor:_notesPanel.leadingAnchor],

    [_notesPanel.topAnchor constraintEqualToAnchor:contentRow.topAnchor],
    [_notesPanel.trailingAnchor constraintEqualToAnchor:contentRow.trailingAnchor],
    [_notesPanel.bottomAnchor constraintEqualToAnchor:contentRow.bottomAnchor],

    [_engineContentView.topAnchor constraintEqualToAnchor:webContainer.topAnchor],
    [_engineContentView.leadingAnchor constraintEqualToAnchor:webContainer.leadingAnchor],
    [_engineContentView.trailingAnchor constraintEqualToAnchor:webContainer.trailingAnchor],
    [_engineContentView.bottomAnchor constraintEqualToAnchor:webContainer.bottomAnchor],

    [_notesResizeHandle.leadingAnchor constraintEqualToAnchor:_notesPanel.leadingAnchor],
    [_notesResizeHandle.topAnchor constraintEqualToAnchor:_notesPanel.topAnchor],
    [_notesResizeHandle.bottomAnchor constraintEqualToAnchor:_notesPanel.bottomAnchor],
    [_notesResizeHandle.widthAnchor constraintEqualToConstant:6.0],

    [notesTitle.topAnchor constraintEqualToAnchor:_notesPanel.topAnchor constant:10],
    [notesTitle.leadingAnchor constraintEqualToAnchor:_notesResizeHandle.trailingAnchor constant:10],

    [clearNotes.centerYAnchor constraintEqualToAnchor:notesTitle.centerYAnchor],
    [clearNotes.trailingAnchor constraintEqualToAnchor:_notesPanel.trailingAnchor constant:-10],
    [clearNotes.widthAnchor constraintEqualToConstant:56],

    [loadNotes.centerYAnchor constraintEqualToAnchor:notesTitle.centerYAnchor],
    [loadNotes.trailingAnchor constraintEqualToAnchor:saveNotes.leadingAnchor constant:-6],
    [loadNotes.widthAnchor constraintEqualToConstant:56],

    [saveNotes.centerYAnchor constraintEqualToAnchor:notesTitle.centerYAnchor],
    [saveNotes.trailingAnchor constraintEqualToAnchor:clearNotes.leadingAnchor constant:-6],
    [saveNotes.widthAnchor constraintEqualToConstant:56],

    [notesScroll.topAnchor constraintEqualToAnchor:notesTitle.bottomAnchor constant:8],
    [notesScroll.leadingAnchor constraintEqualToAnchor:_notesResizeHandle.trailingAnchor constant:10],
    [notesScroll.trailingAnchor constraintEqualToAnchor:_notesPanel.trailingAnchor constant:-10],
    [notesScroll.bottomAnchor constraintEqualToAnchor:_notesPanel.bottomAnchor constant:-10],

    [devTitle.topAnchor constraintEqualToAnchor:_devPanel.topAnchor constant:8],
    [devTitle.leadingAnchor constraintEqualToAnchor:_devPanel.leadingAnchor constant:10],

    [runDev.centerYAnchor constraintEqualToAnchor:devTitle.centerYAnchor],
    [runDev.trailingAnchor constraintEqualToAnchor:clearDev.leadingAnchor constant:-6],
    [runDev.widthAnchor constraintEqualToConstant:64],

    [pageSource.centerYAnchor constraintEqualToAnchor:devTitle.centerYAnchor],
    [pageSource.trailingAnchor constraintEqualToAnchor:runDev.leadingAnchor constant:-6],
    [pageSource.widthAnchor constraintEqualToConstant:92],

    [dataSummary.centerYAnchor constraintEqualToAnchor:devTitle.centerYAnchor],
    [dataSummary.trailingAnchor constraintEqualToAnchor:pageSource.leadingAnchor constant:-6],
    [dataSummary.widthAnchor constraintEqualToConstant:96],

    [clearDev.centerYAnchor constraintEqualToAnchor:devTitle.centerYAnchor],
    [clearDev.trailingAnchor constraintEqualToAnchor:_devPanel.trailingAnchor constant:-10],
    [clearDev.widthAnchor constraintEqualToConstant:58],

    [_devInputField.topAnchor constraintEqualToAnchor:devTitle.bottomAnchor constant:6],
    [_devInputField.leadingAnchor constraintEqualToAnchor:_devPanel.leadingAnchor constant:10],
    [_devInputField.trailingAnchor constraintEqualToAnchor:_devPanel.trailingAnchor constant:-10],

    [devScroll.topAnchor constraintEqualToAnchor:_devInputField.bottomAnchor constant:6],
    [devScroll.leadingAnchor constraintEqualToAnchor:_devPanel.leadingAnchor constant:10],
    [devScroll.trailingAnchor constraintEqualToAnchor:_devPanel.trailingAnchor constant:-10],
    [devScroll.bottomAnchor constraintEqualToAnchor:_devPanel.bottomAnchor constant:-8],

    [_statusBar.leadingAnchor constraintEqualToAnchor:_rootView.leadingAnchor],
    [_statusBar.trailingAnchor constraintEqualToAnchor:_rootView.trailingAnchor],
    [_statusBar.bottomAnchor constraintEqualToAnchor:_rootView.bottomAnchor],
    [_statusBar.heightAnchor constraintEqualToConstant:26],

    [_statusLeftLabel.leadingAnchor constraintEqualToAnchor:_statusBar.leadingAnchor constant:10],
    [_statusLeftLabel.centerYAnchor constraintEqualToAnchor:_statusBar.centerYAnchor],

    [_statusRightLabel.trailingAnchor constraintEqualToAnchor:_statusBar.trailingAnchor constant:-10],
    [_statusRightLabel.centerYAnchor constraintEqualToAnchor:_statusBar.centerYAnchor],
    [_statusRightLabel.leadingAnchor constraintGreaterThanOrEqualToAnchor:_statusLeftLabel.trailingAnchor constant:10],
  ]];
  [self applyTheme];
}

- (void)showWindow {
  [_window makeKeyAndOrderFront:nil];
  [NSApp activateIgnoringOtherApps:YES];
  [self applyTheme];
  [self updateAddressSecurityAndNav];
  [self updateBookmarkButtonState];

  if (_webView && !_observingWebView) {
    [_webView addObserver:self
               forKeyPath:@"estimatedProgress"
                  options:NSKeyValueObservingOptionNew
                  context:nil];
    _observingWebView = true;
  }

  if (!_keyMonitor) {
    __weak PriFacieBrowserController* weakSelf = self;
    _keyMonitor = [NSEvent
        addLocalMonitorForEventsMatchingMask:NSEventMaskKeyDown
                                     handler:^NSEvent*(NSEvent* event) {
                                       if (!weakSelf) return event;
                                       return [weakSelf handleKeyShortcut:event] ? nil : event;
    }];
  }
}

- (void)dealloc {
  if (_currentServerTrust) {
    CFRelease(_currentServerTrust);
    _currentServerTrust = nullptr;
  }
}

- (BOOL)ownsWindow:(NSWindow*)window {
  return window == _window;
}

- (void)appendDevLog:(NSString*)line {
  if (!line) return;
  NSString* timestamp = [[NSDate date] descriptionWithLocale:nil];
  [_devLogBuffer appendFormat:@"[%@] %@\n", timestamp, line];
  _devTextView.string = _devLogBuffer;
  [_devTextView scrollRangeToVisible:NSMakeRange(_devTextView.string.length, 0)];
}

- (void)toggleDevPanelVisible:(BOOL)visible {
  _devPanelVisible = visible;
  _devPanel.hidden = !visible;
  _devPanelHeightConstraint.constant = visible ? 240.0 : 0.0;
  [_window.contentView layoutSubtreeIfNeeded];
}

- (void)onToggleDevPanel:(id)sender {
  (void)sender;
  [self toggleDevPanelVisible:!_devPanelVisible];
}

- (void)onRunDevScript:(id)sender {
  (void)sender;
  NSString* source = _devInputField.stringValue ? _devInputField.stringValue : @"";
  if (source.length == 0) {
    [self toggleDevPanelVisible:YES];
    [_window makeFirstResponder:_devInputField];
    return;
  }
  [self appendDevLog:[NSString stringWithFormat:@"[JS]> %@", source]];
  [_webView evaluateJavaScript:source
             completionHandler:^(id result, NSError* error) {
               if (error) {
                 [self appendDevLog:[NSString stringWithFormat:@"[JS ERROR] %@", error.localizedDescription]];
                 return;
               }
               NSString* text = result ? [NSString stringWithFormat:@"%@", result] : @"undefined";
               [self appendDevLog:[NSString stringWithFormat:@"[JS RESULT] %@", text]];
             }];
}

- (void)onLoadPageSource:(id)sender {
  (void)sender;
  [_webView evaluateJavaScript:@"document.documentElement.outerHTML"
             completionHandler:^(id result, NSError* error) {
               if (error || ![result isKindOfClass:[NSString class]]) {
                 [self appendDevLog:[NSString stringWithFormat:@"[SOURCE ERROR] %@",
                                                              error ? error.localizedDescription : @"Unknown error"]];
                 return;
               }
               NSString* html = (NSString*)result;
               const NSUInteger max_dump = 6000;
               if (html.length > max_dump) {
                 html = [[html substringToIndex:max_dump] stringByAppendingString:@"\n... (truncated)"];
               }
               [self appendDevLog:@"[PAGE SOURCE]"];
               [self appendDevLog:html];
             }];
}

- (void)onDumpWebsiteDataSummary:(id)sender {
  (void)sender;
  __weak PriFacieBrowserController* weakSelf = self;
  [_engineAdapter dumpWebsiteDataSummary:^(NSArray<NSString*>* lines) {
    PriFacieBrowserController* strongSelf = weakSelf;
    if (!strongSelf) return;
    for (NSString* line in lines) {
      [strongSelf appendDevLog:line];
    }
  }];
}

- (void)onClearDevLogs:(id)sender {
  (void)sender;
  [_devLogBuffer setString:@""];
  _devTextView.string = @"";
}

- (void)onOpenLocationPrompt:(id)sender {
  (void)sender;
  std::string entered;
  if (!PromptSingleText(@"Open Location", @"Enter URL, host, or search query.", @"https://example.com",
                        false, &entered)) {
    return;
  }
  [self navigateFromAddressInput:ToNSString(entered)];
}

- (void)onOpenFile:(id)sender {
  (void)sender;
  NSOpenPanel* panel = [NSOpenPanel openPanel];
  panel.title = @"Open File";
  panel.allowsMultipleSelection = NO;
  if ([panel runModal] != NSModalResponseOK || panel.URLs.count == 0) return;
  NSURL* url = panel.URLs.firstObject;
  if (!url) return;
  [_webView loadFileURL:url allowingReadAccessToURL:url.URLByDeletingLastPathComponent];
}

- (void)onOpenDownloadsManagerTab:(id)sender {
  (void)sender;
  [self openAdditionalTabWithUrl:ToNSString(kDownloadsManagerUrl)];
}

- (void)onChooseDownloadFolder:(id)sender {
  (void)sender;
  NSOpenPanel* panel = [NSOpenPanel openPanel];
  panel.title = @"Choose Downloads Folder";
  panel.canChooseFiles = NO;
  panel.canChooseDirectories = YES;
  panel.canCreateDirectories = YES;
  panel.allowsMultipleSelection = NO;
  if (_downloadTargetFolder.length > 0) {
    panel.directoryURL = [NSURL fileURLWithPath:_downloadTargetFolder];
  } else {
    panel.directoryURL = [NSURL fileURLWithPath:[self defaultDownloadFolderPath]];
  }
  if ([panel runModal] != NSModalResponseOK || panel.URLs.count == 0) return;
  NSURL* selected = panel.URLs.firstObject;
  if (!selected || !selected.path.length) return;
  _downloadTargetFolder = selected.path;
  _settings.download_folder = ToStdString(_downloadTargetFolder);
  [self saveSettings];
  [self refreshDownloadsManagerIfVisible];
  ShowInfo(@"Downloads", [NSString stringWithFormat:@"Downloads folder set to:\n%@", _downloadTargetFolder]);
}

- (void)onDownloadFromUrlPrompt:(id)sender {
  (void)sender;
  std::string entered;
  if (!PromptSingleText(@"Download From URL",
                        @"Enter a direct HTTP/HTTPS URL to download.",
                        @"https://example.com/file.zip",
                        false,
                        &entered)) {
    return;
  }
  [self enqueueDownloadFromInputText:ToNSString(entered)];
}

- (void)onCloseWindow:(id)sender {
  (void)sender;
  if (@available(macOS 10.12, *)) {
    NSArray<NSWindow*>* tabbed = _window.tabbedWindows;
    if (tabbed.count > 1) {
      [_window moveTabToNewWindow:nil];
    }
  }
  [_window performClose:nil];
}

- (void)applyTheme {
  const bool dark = _settings.dark_mode;
  _window.appearance = dark ? [NSAppearance appearanceNamed:NSAppearanceNameDarkAqua]
                            : [NSAppearance appearanceNamed:NSAppearanceNameAqua];

  NSColor* top_bg = dark ? NSColor.blackColor : [NSColor colorWithCalibratedWhite:0.965 alpha:1.0];
  NSColor* panel_bg = dark ? NSColor.blackColor : [NSColor colorWithCalibratedWhite:0.985 alpha:1.0];
  NSColor* text = dark ? NSColor.whiteColor : [NSColor colorWithCalibratedWhite:0.08 alpha:1.0];
  NSColor* secondary = dark ? [NSColor colorWithCalibratedWhite:0.84 alpha:1.0]
                            : [NSColor colorWithCalibratedWhite:0.33 alpha:1.0];
  NSColor* button_bg = dark ? [NSColor colorWithCalibratedWhite:0.14 alpha:1.0]
                            : [NSColor colorWithCalibratedWhite:0.93 alpha:1.0];
  NSColor* button_border = dark ? [NSColor colorWithCalibratedWhite:0.30 alpha:1.0]
                                : [NSColor colorWithCalibratedWhite:0.80 alpha:1.0];

  if (_rootView.layer) _rootView.layer.backgroundColor = top_bg.CGColor;
  if (_topBar.layer) _topBar.layer.backgroundColor = top_bg.CGColor;
  if (_statusBar.layer) {
    _statusBar.layer.backgroundColor = panel_bg.CGColor;
    _statusBar.layer.borderColor =
        (dark ? [NSColor colorWithCalibratedWhite:0.25 alpha:1.0] : NSColor.separatorColor).CGColor;
  }
  if (_devPanel.layer) {
    _devPanel.layer.backgroundColor = panel_bg.CGColor;
    _devPanel.layer.borderColor =
        (dark ? [NSColor colorWithCalibratedWhite:0.25 alpha:1.0] : NSColor.separatorColor).CGColor;
  }
  if (_notesPanel.layer) _notesPanel.layer.backgroundColor = panel_bg.CGColor;
  if (_notesResizeHandle.layer) {
    _notesResizeHandle.layer.backgroundColor =
        (dark ? [NSColor colorWithCalibratedWhite:0.34 alpha:1.0]
              : [NSColor colorWithCalibratedWhite:0.78 alpha:1.0]).CGColor;
  }

  _statusLeftLabel.textColor = secondary;
  _statusRightLabel.textColor = text;
  _addressField.backgroundColor = dark ? NSColor.blackColor : NSColor.textBackgroundColor;
  _addressField.textColor = text;

  _notesTextView.backgroundColor = dark ? NSColor.blackColor : NSColor.textBackgroundColor;
  _notesTextView.textColor = text;
  _notesTextView.insertionPointColor = text;
  _devInputField.backgroundColor = dark ? NSColor.blackColor : NSColor.textBackgroundColor;
  _devInputField.textColor = text;
  _devTextView.backgroundColor = dark ? NSColor.blackColor : NSColor.textBackgroundColor;
  _devTextView.textColor = text;

  NSArray<NSButton*>* buttons = @[_backButton,        _forwardButton,   _reloadButton,
                                  _homeButton,        _bookmarkToggleButton, _bookmarksButton,
                                  _historyButton,     _toolsButton,      _notesToggleButton,
                                  _profileButton,     _lockButton];
  for (NSButton* button in buttons) {
    if (!button) continue;
    button.wantsLayer = YES;
    button.layer.cornerRadius = 6.0;
    button.layer.masksToBounds = YES;
    button.layer.backgroundColor = button_bg.CGColor;
    button.layer.borderColor = button_border.CGColor;
    button.layer.borderWidth = 1.0;
    if ([button respondsToSelector:@selector(setContentTintColor:)]) {
      button.contentTintColor = text;
    }
    if (button.attributedTitle.length > 0) {
      NSMutableAttributedString* mutable_title =
          [[NSMutableAttributedString alloc] initWithAttributedString:button.attributedTitle];
      [mutable_title addAttribute:NSForegroundColorAttributeName
                            value:text
                            range:NSMakeRange(0, mutable_title.length)];
      button.attributedTitle = mutable_title;
    }
  }
  NSString* profile_title = [NSString stringWithFormat:@" %@ ", ToNSString(_profileName)];
  _profileButton.attributedTitle = [[NSAttributedString alloc]
      initWithString:profile_title
          attributes:@{
            NSForegroundColorAttributeName : text,
            NSFontAttributeName : [NSFont systemFontOfSize:11 weight:NSFontWeightSemibold],
          }];
}

- (BOOL)handleKeyShortcut:(NSEvent*)event {
  if (!event) return NO;
  const NSEventModifierFlags mods = (event.modifierFlags & NSEventModifierFlagDeviceIndependentFlagsMask);
  const bool command = (mods & NSEventModifierFlagCommand) != 0;
  const bool control = (mods & NSEventModifierFlagControl) != 0;

  NSString* key = event.charactersIgnoringModifiers.lowercaseString
                      ? event.charactersIgnoringModifiers.lowercaseString
                      : @"";
  const bool shift = (mods & NSEventModifierFlagShift) != 0;

  if (control && !command) {
    if ([key isEqualToString:@"t"]) {
      [self onNewTab:nil];
      return YES;
    }
    if ([key isEqualToString:@"n"]) {
      [self onNewWindow:nil];
      return YES;
    }
  }

  if (!command) return NO;
  if (event.keyCode == kKeyCodeLeftArrow) {
    [self onBack:nil];
    return YES;
  }
  if (event.keyCode == kKeyCodeRightArrow) {
    [self onForward:nil];
    return YES;
  }

  if (!shift && [key isEqualToString:@"n"]) {
    [self onNewWindow:nil];
    return YES;
  }
  if ([key isEqualToString:@"t"]) {
    [self onNewTab:nil];
    return YES;
  }
  if ([key isEqualToString:@"w"]) {
    [self onCloseWindow:nil];
    return YES;
  }
  if ([key isEqualToString:@"p"]) {
    [self onPrint:nil];
    return YES;
  }

  if (shift && [key isEqualToString:@"l"]) {
    [self onLockBrowser:nil];
    return YES;
  }
  if (shift && [key isEqualToString:@"d"]) {
    [self onToggleDarkMode:nil];
    return YES;
  }
  if ([key isEqualToString:@"l"]) {
    [_window makeFirstResponder:_addressField];
    [_addressField selectText:nil];
    return YES;
  }
  if ([key isEqualToString:@"r"]) {
    [self onReload:nil];
    return YES;
  }
  if ([key isEqualToString:@"j"]) {
    [self onOpenDownloadsManagerTab:nil];
    return YES;
  }
  if ([key isEqualToString:@"f"]) {
    [self onFindInPage:nil];
    return YES;
  }
  if ([key isEqualToString:@"d"]) {
    [self onToggleCurrentBookmark:nil];
    return YES;
  }
  if ([key isEqualToString:@"b"]) {
    [self onBookmarksMenuButton:nil];
    return YES;
  }
  if ([key isEqualToString:@"y"]) {
    [self onHistoryMenuButton:nil];
    return YES;
  }
  if ([key isEqualToString:@"["]) {
    [self onBack:nil];
    return YES;
  }
  if ([key isEqualToString:@"]"]) {
    [self onForward:nil];
    return YES;
  }
  if ([key isEqualToString:@"0"]) {
    [self onResetZoom:nil];
    return YES;
  }
  if ([key isEqualToString:@"="] || [key isEqualToString:@"+"]) {
    [self onZoomIn:nil];
    return YES;
  }
  if ([key isEqualToString:@"-"]) {
    [self onZoomOut:nil];
    return YES;
  }
  if (shift && [key isEqualToString:@"n"]) {
    [self onToggleNotesPanel:nil];
    return YES;
  }
  return NO;
}

- (void)observeValueForKeyPath:(NSString*)keyPath
                      ofObject:(id)object
                        change:(NSDictionary<NSKeyValueChangeKey, id>*)change
                       context:(void*)context {
  (void)change;
  (void)context;
  if (object == _webView && [keyPath isEqualToString:@"estimatedProgress"]) {
    [self updateAddressSecurityAndNav];
    return;
  }
  [super observeValueForKeyPath:keyPath ofObject:object change:change context:context];
}

- (void)saveSettings {
  _profileStore->SaveSettings(_profileName, _settings);
}

- (void)persistEncryptedBrowserData {
  if (!_browserData->Save(_sessionKey)) {
    ShowError(@"Encrypted Vault", @"Failed saving encrypted browser data.");
  }
}

- (void)persistNotesFromEditor {
  if (!_notesTextView) return;
  _browserData->SetNotes(ToStdString(_notesTextView.string));
}

- (void)updateAddressSecurityAndNav {
  NSString* absolute = _webView.URL.absoluteString ? _webView.URL.absoluteString : @"";
  _addressField.stringValue = absolute;

  NSString* scheme = _webView.URL.scheme.lowercaseString ? _webView.URL.scheme.lowercaseString : @"";
  if ([scheme isEqualToString:@"https"]) {
    _securityBadge.stringValue = @" HTTPS ";
    _securityBadge.layer.backgroundColor =
        [[NSColor colorWithCalibratedRed:0.07 green:0.55 blue:0.22 alpha:1.0] CGColor];
  } else if ([scheme isEqualToString:@"file"]) {
    _securityBadge.stringValue = @" LOCAL ";
    _securityBadge.layer.backgroundColor =
        [[NSColor colorWithCalibratedRed:0.29 green:0.37 blue:0.76 alpha:1.0] CGColor];
  } else {
    _securityBadge.stringValue = @" UNSECURE ";
    _securityBadge.layer.backgroundColor =
        [[NSColor colorWithCalibratedRed:0.72 green:0.22 blue:0.20 alpha:1.0] CGColor];
  }

  _backButton.enabled = _webView.canGoBack;
  _forwardButton.enabled = _webView.canGoForward;

  const int zoom_percent = static_cast<int>(std::lround([self currentZoom] * 100.0));
  const int progress_percent = static_cast<int>(std::lround(_webView.estimatedProgress * 100.0));
  _statusRightLabel.stringValue =
      [NSString stringWithFormat:@"Zoom %d%%  |  Load %d%%", zoom_percent, progress_percent];

  if (_hoveredLink.length > 0) {
    _statusLeftLabel.stringValue =
        [NSString stringWithFormat:@"Profile: %s  |  Link: %@  |  Ephemeral Web Data",
                                   _profileName.c_str(), _hoveredLink];
  } else if (absolute.length > 0) {
    _statusLeftLabel.stringValue =
        [NSString stringWithFormat:@"Profile: %s  |  %@  |  Ephemeral Web Data",
                                   _profileName.c_str(), absolute];
  } else {
    _statusLeftLabel.stringValue =
        [NSString stringWithFormat:@"Profile: %s  |  Ready  |  Ephemeral Web Data", _profileName.c_str()];
  }
}

- (void)updateBookmarkButtonState {
  const std::string current = ToStdString(_webView.URL.absoluteString);
  const bool bookmarked = _browserData->IsBookmarked(current);
  SetButtonIcon(_bookmarkToggleButton, bookmarked ? 0xF005 : 0xF006, @"Toggle Bookmark", 12,
                bookmarked);
}

- (void)loadURLString:(NSString*)url_string {
  if (!_webView) return;
  NSURL* internal = [NSURL URLWithString:url_string];
  if (internal && [internal.scheme.lowercaseString isEqualToString:@"prifacie"] &&
      [internal.host.lowercaseString isEqualToString:@"downloads"]) {
    [self loadDownloadsManagerPage];
    return;
  }
  NSURL* url = [NSURL URLWithString:url_string];
  if (!url) return;
  NSURLRequest* request = [NSURLRequest requestWithURL:url];
  [_webView loadRequest:request];
}

- (void)navigateFromAddressInput:(NSString*)input {
  const std::string uri = ResolveNavigationUrl(_settings, input);
  if (uri.empty()) return;
  [self loadURLString:ToNSString(uri)];
}

- (NSString*)extractOrigin:(NSURL*)url {
  if (!url.scheme || !url.host) return @"";
  NSString* out = [NSString stringWithFormat:@"%@://%@", url.scheme.lowercaseString, url.host.lowercaseString];
  if (url.port) out = [out stringByAppendingFormat:@":%@", url.port];
  return out;
}

- (void)recordCurrentPageInHistory {
  NSURL* url = _webView.URL;
  if (!url || !url.scheme) return;
  NSString* scheme = url.scheme.lowercaseString;
  if (!([scheme isEqualToString:@"http"] || [scheme isEqualToString:@"https"] ||
        [scheme isEqualToString:@"file"])) {
    return;
  }

  const std::string url_str = ToStdString(url.absoluteString);
  std::string title = ToStdString(_webView.title);
  if (title.empty()) title = url_str;

  _browserData->AddHistory(url_str, title, NowEpochSeconds());
  [self persistEncryptedBrowserData];
}

- (void)toggleCurrentBookmark {
  const std::string url = ToStdString(_webView.URL.absoluteString);
  if (url.empty()) return;

  if (_browserData->IsBookmarked(url)) {
    _browserData->RemoveBookmark(url);
  } else {
    std::string title = ToStdString(_webView.title);
    if (title.empty()) title = url;
    _browserData->AddBookmark(url, title, NowEpochSeconds());
  }
  [self persistEncryptedBrowserData];
  [self updateBookmarkButtonState];
}

- (void)showMenu:(NSMenu*)menu fromButton:(NSButton*)button {
  if (!menu || !button) return;
  [menu popUpMenuPositioningItem:nil atLocation:NSMakePoint(0, NSHeight(button.bounds) + 2) inView:button];
}

- (void)rebuildBookmarksMenu {
  [_bookmarksMenu removeAllItems];

  const std::string current_url = ToStdString(_webView.URL.absoluteString);
  const bool is_bookmarked = _browserData->IsBookmarked(current_url);
  NSMenuItem* toggleItem =
      [[NSMenuItem alloc] initWithTitle:(is_bookmarked ? @"Remove Bookmark for Current Page"
                                                      : @"Add Bookmark for Current Page")
                                 action:@selector(onToggleCurrentBookmark:)
                          keyEquivalent:@""];
  toggleItem.target = self;
  [_bookmarksMenu addItem:toggleItem];

  NSMenuItem* clearItem = [[NSMenuItem alloc] initWithTitle:@"Clear All Bookmarks"
                                                     action:@selector(onClearBookmarks:)
                                              keyEquivalent:@""];
  clearItem.target = self;
  [_bookmarksMenu addItem:clearItem];
  [_bookmarksMenu addItem:[NSMenuItem separatorItem]];

  const auto& entries = _browserData->Bookmarks();
  if (entries.empty()) {
    NSMenuItem* empty = [[NSMenuItem alloc] initWithTitle:@"No bookmarks yet"
                                                   action:nil
                                            keyEquivalent:@""];
    empty.enabled = NO;
    [_bookmarksMenu addItem:empty];
    return;
  }

  for (auto it = entries.rbegin(); it != entries.rend(); ++it) {
    NSString* label = TrimTitle(it->title.empty() ? it->url : it->title);
    NSMenuItem* item = [[NSMenuItem alloc] initWithTitle:label
                                                  action:@selector(onOpenUrlMenuItem:)
                                           keyEquivalent:@""];
    item.target = self;
    item.representedObject = ToNSString(it->url);
    item.toolTip = ToNSString(it->url);
    [_bookmarksMenu addItem:item];
  }
}

- (void)rebuildHistoryMenu {
  [_historyMenu removeAllItems];

  NSMenuItem* clearItem = [[NSMenuItem alloc] initWithTitle:@"Clear History"
                                                     action:@selector(onClearHistory:)
                                              keyEquivalent:@""];
  clearItem.target = self;
  [_historyMenu addItem:clearItem];
  [_historyMenu addItem:[NSMenuItem separatorItem]];

  const auto& entries = _browserData->History();
  if (entries.empty()) {
    NSMenuItem* empty = [[NSMenuItem alloc] initWithTitle:@"No history yet"
                                                   action:nil
                                            keyEquivalent:@""];
    empty.enabled = NO;
    [_historyMenu addItem:empty];
    return;
  }

  std::size_t shown = 0;
  for (auto it = entries.rbegin(); it != entries.rend() && shown < 60; ++it, ++shown) {
    NSString* label = TrimTitle(it->title.empty() ? it->url : it->title);
    NSMenuItem* item = [[NSMenuItem alloc] initWithTitle:label
                                                  action:@selector(onOpenUrlMenuItem:)
                                           keyEquivalent:@""];
    item.target = self;
    item.representedObject = ToNSString(it->url);
    item.toolTip = ToNSString(it->url);
    [_historyMenu addItem:item];
  }
}

- (void)addToolsCheckItem:(NSString*)title action:(SEL)action enabled:(bool)enabled {
  NSMenuItem* item = [[NSMenuItem alloc] initWithTitle:title action:action keyEquivalent:@""];
  item.target = self;
  item.state = enabled ? NSControlStateValueOn : NSControlStateValueOff;
  [_toolsMenu addItem:item];
}

- (void)addSearchEngineItem:(NSMenu*)menu title:(NSString*)title urlPrefix:(const std::string&)prefix {
  NSMenuItem* item = [[NSMenuItem alloc] initWithTitle:title
                                                action:@selector(onSelectSearchEngine:)
                                         keyEquivalent:@""];
  item.target = self;
  item.representedObject = ToNSString(prefix);
  item.state = (_settings.search_engine == prefix) ? NSControlStateValueOn : NSControlStateValueOff;
  [menu addItem:item];
}

- (void)rebuildToolsMenu {
  [_toolsMenu removeAllItems];

  NSMenuItem* aboutItem =
      [[NSMenuItem alloc] initWithTitle:@"About PriFacie" action:@selector(onAboutPriFacie:) keyEquivalent:@""];
  aboutItem.target = self;
  [_toolsMenu addItem:aboutItem];

  NSMenuItem* certItem =
      [[NSMenuItem alloc] initWithTitle:@"View Site Certificate"
                                 action:@selector(onViewSiteCertificate:)
                          keyEquivalent:@""];
  certItem.target = self;
  [_toolsMenu addItem:certItem];

  NSMenuItem* downloadsTab =
      [[NSMenuItem alloc] initWithTitle:@"Open Downloads Manager Tab"
                                 action:@selector(onOpenDownloadsManagerTab:)
                          keyEquivalent:@""];
  downloadsTab.target = self;
  [_toolsMenu addItem:downloadsTab];

  NSMenuItem* chooseFolder =
      [[NSMenuItem alloc] initWithTitle:@"Select Downloads Folder..."
                                 action:@selector(onChooseDownloadFolder:)
                          keyEquivalent:@""];
  chooseFolder.target = self;
  [_toolsMenu addItem:chooseFolder];

  NSMenuItem* downloadFromUrl =
      [[NSMenuItem alloc] initWithTitle:@"Download From URL..."
                                 action:@selector(onDownloadFromUrlPrompt:)
                          keyEquivalent:@""];
  downloadFromUrl.target = self;
  [_toolsMenu addItem:downloadFromUrl];
  [_toolsMenu addItem:[NSMenuItem separatorItem]];

  NSMenuItem* setHomeCurrent = [[NSMenuItem alloc] initWithTitle:@"Set Current Page as Home"
                                                          action:@selector(onSetCurrentPageAsHome:)
                                                   keyEquivalent:@""];
  setHomeCurrent.target = self;
  [_toolsMenu addItem:setHomeCurrent];
  NSMenuItem* setHomeCustom = [[NSMenuItem alloc] initWithTitle:@"Set Home Page URL..."
                                                         action:@selector(onSetHomePageUrl:)
                                                  keyEquivalent:@""];
  setHomeCustom.target = self;
  [_toolsMenu addItem:setHomeCustom];
  NSMenuItem* resetHome = [[NSMenuItem alloc] initWithTitle:@"Reset Home Page to Default"
                                                     action:@selector(onResetHomePageDefault:)
                                              keyEquivalent:@""];
  resetHome.target = self;
  [_toolsMenu addItem:resetHome];

  NSMenu* searchMenu = [[NSMenu alloc] initWithTitle:@"Search Engine"];
  [self addSearchEngineItem:searchMenu title:@"DuckDuckGo" urlPrefix:"https://duckduckgo.com/?q="];
  [self addSearchEngineItem:searchMenu title:@"Google" urlPrefix:"https://www.google.com/search?q="];
  [self addSearchEngineItem:searchMenu title:@"Brave Search" urlPrefix:"https://search.brave.com/search?q="];
  [self addSearchEngineItem:searchMenu title:@"Bing" urlPrefix:"https://www.bing.com/search?q="];
  NSMenuItem* searchRoot = [[NSMenuItem alloc] initWithTitle:@"Search Engine"
                                                      action:nil
                                               keyEquivalent:@""];
  [_toolsMenu addItem:searchRoot];
  [_toolsMenu setSubmenu:searchMenu forItem:searchRoot];

  [_toolsMenu addItem:[NSMenuItem separatorItem]];

  [self addToolsCheckItem:@"HTTPS-Only Mode" action:@selector(onToggleHttpsOnly:) enabled:_settings.https_only];
  [self addToolsCheckItem:@"Block Common Trackers" action:@selector(onToggleTrackers:) enabled:_settings.block_trackers];
  [self addToolsCheckItem:@"Block Third-Party Cookies" action:@selector(onToggleThirdParty:) enabled:_settings.block_third_party_cookies];
  [self addToolsCheckItem:@"Enable JavaScript" action:@selector(onToggleJavascript:) enabled:_settings.javascript_enabled];
  [self addToolsCheckItem:@"Clear Website Data On Exit" action:@selector(onToggleClearOnExit:) enabled:_settings.clear_data_on_exit];
  [self addToolsCheckItem:@"Dark Mode (Black)" action:@selector(onToggleDarkMode:) enabled:_settings.dark_mode];
  [_toolsMenu addItem:[NSMenuItem separatorItem]];

  NSMenuItem* saveCred = [[NSMenuItem alloc] initWithTitle:@"Save Credentials for This Site"
                                                    action:@selector(onSaveCredentials:)
                                             keyEquivalent:@""];
  saveCred.target = self;
  [_toolsMenu addItem:saveCred];

  NSMenuItem* fillCred = [[NSMenuItem alloc] initWithTitle:@"Autofill Saved Credentials"
                                                    action:@selector(onAutofillCredentials:)
                                             keyEquivalent:@""];
  fillCred.target = self;
  [_toolsMenu addItem:fillCred];

  [_toolsMenu addItem:[NSMenuItem separatorItem]];

  NSMenuItem* findItem = [[NSMenuItem alloc] initWithTitle:@"Find in Page"
                                                    action:@selector(onFindInPage:)
                                             keyEquivalent:@""];
  findItem.target = self;
  [_toolsMenu addItem:findItem];

  NSMenuItem* zoomIn = [[NSMenuItem alloc] initWithTitle:@"Zoom In"
                                                  action:@selector(onZoomIn:)
                                           keyEquivalent:@""];
  zoomIn.target = self;
  [_toolsMenu addItem:zoomIn];

  NSMenuItem* zoomOut = [[NSMenuItem alloc] initWithTitle:@"Zoom Out"
                                                   action:@selector(onZoomOut:)
                                            keyEquivalent:@""];
  zoomOut.target = self;
  [_toolsMenu addItem:zoomOut];

  NSMenuItem* zoomReset = [[NSMenuItem alloc] initWithTitle:@"Reset Zoom"
                                                     action:@selector(onResetZoom:)
                                              keyEquivalent:@""];
  zoomReset.target = self;
  [_toolsMenu addItem:zoomReset];

  [_toolsMenu addItem:[NSMenuItem separatorItem]];

  NSMenuItem* exportBm = [[NSMenuItem alloc] initWithTitle:@"Export Bookmarks..."
                                                    action:@selector(onExportBookmarks:)
                                             keyEquivalent:@""];
  exportBm.target = self;
  [_toolsMenu addItem:exportBm];

  NSMenuItem* importBm = [[NSMenuItem alloc] initWithTitle:@"Import Bookmarks..."
                                                    action:@selector(onImportBookmarks:)
                                             keyEquivalent:@""];
  importBm.target = self;
  [_toolsMenu addItem:importBm];
  [_toolsMenu addItem:[NSMenuItem separatorItem]];

  NSMenuItem* clearData = [[NSMenuItem alloc] initWithTitle:@"Clear Browsing Data Now"
                                                     action:@selector(onClearNow:)
                                              keyEquivalent:@""];
  clearData.target = self;
  [_toolsMenu addItem:clearData];

  NSMenuItem* newProfile = [[NSMenuItem alloc] initWithTitle:@"Create New Profile"
                                                      action:@selector(onCreateProfile:)
                                               keyEquivalent:@""];
  newProfile.target = self;
  [_toolsMenu addItem:newProfile];
}

- (void)rebuildProfileMenu {
  [_profileMenu removeAllItems];

  NSMenuItem* about = [[NSMenuItem alloc] initWithTitle:@"About PriFacie"
                                                 action:@selector(onAboutPriFacie:)
                                          keyEquivalent:@""];
  about.target = self;
  [_profileMenu addItem:about];
  [_profileMenu addItem:[NSMenuItem separatorItem]];

  NSMenuItem* title = [[NSMenuItem alloc] initWithTitle:[NSString stringWithFormat:@"Profile: %s", _profileName.c_str()]
                                                 action:nil
                                          keyEquivalent:@""];
  title.enabled = NO;
  [_profileMenu addItem:title];
  [_profileMenu addItem:[NSMenuItem separatorItem]];

  NSMenuItem* lock = [[NSMenuItem alloc] initWithTitle:@"Lock Browser"
                                                action:@selector(onLockBrowser:)
                                         keyEquivalent:@""];
  lock.target = self;
  [_profileMenu addItem:lock];

  NSMenuItem* dark = [[NSMenuItem alloc] initWithTitle:@"Toggle Dark Mode"
                                                action:@selector(onToggleDarkMode:)
                                         keyEquivalent:@""];
  dark.target = self;
  dark.state = _settings.dark_mode ? NSControlStateValueOn : NSControlStateValueOff;
  [_profileMenu addItem:dark];

  [_profileMenu addItem:[NSMenuItem separatorItem]];
  NSMenuItem* erase = [[NSMenuItem alloc] initWithTitle:@"Delete Profile Permanently"
                                                 action:@selector(onDeleteCurrentProfile:)
                                          keyEquivalent:@""];
  erase.target = self;
  [_profileMenu addItem:erase];
}

- (void)applyPrivacySettings {
  [_engineAdapter applyPrivacySettings:_settings trackerDomains:_trackerDomains];
  _webDataIsEphemeral = _engineAdapter.webDataEphemeral;
  NSString* webDataState = _webDataIsEphemeral ? @"Ephemeral" : @"Engine-managed";
  _statusLeftLabel.stringValue =
      [NSString stringWithFormat:@"Profile: %s  |  Engine: %@  |  Vault: Encrypted  |  Web Data: %@",
                                 _profileName.c_str(),
                                 [_engineAdapter engineDisplayName],
                                 webDataState];
  [self saveSettings];
}

- (void)saveCredentialsForCurrentSite {
  NSString* origin = [self extractOrigin:_webView.URL];
  if (origin.length == 0) {
    ShowError(@"Credential Vault", @"Current tab does not have a valid web origin.");
    return;
  }

  SavedCredential cred;
  if (!PromptCredential(origin, &cred)) return;
  _credentialStore->Upsert(cred);
  if (!_credentialStore->Save(_sessionKey)) {
    ShowError(@"Credential Vault", @"Failed to encrypt and save credentials.");
    return;
  }
  ShowInfo(@"Credential Vault", @"Credentials saved to encrypted profile storage.");
}

- (void)autofillCredentialsForCurrentSite {
  NSString* origin = [self extractOrigin:_webView.URL];
  if (origin.length == 0) return;

  auto saved = _credentialStore->FindByOrigin(ToStdString(origin));
  if (!saved.has_value()) {
    ShowInfo(@"Credential Vault", @"No saved credentials for this site.");
    return;
  }

  std::string js =
      "(function(){"
      "const user='" +
      JsEscape(saved->username) +
      "';"
      "const pass='" +
      JsEscape(saved->password) +
      "';"
      "const userField=document.querySelector(\"input[type='email'],input[name*='user' i],input[id*='user' i],input[name*='email' i],input[type='text']\");"
      "const passField=document.querySelector(\"input[type='password']\");"
      "if(userField){userField.value=user; userField.dispatchEvent(new Event('input',{bubbles:true}));}"
      "if(passField){passField.value=pass; passField.dispatchEvent(new Event('input',{bubbles:true}));}"
      "})();";
  [_webView evaluateJavaScript:ToNSString(js) completionHandler:nil];
  ShowInfo(@"Credential Vault", @"Autofill script executed.");
}

- (void)clearBrowsingDataSilent:(BOOL)silent completion:(dispatch_block_t)completion {
  [_engineAdapter clearBrowsingDataWithCompletion:^{
    if (!silent) ShowInfo(@"Privacy", @"Browsing data was cleared.");
    if (completion) completion();
  }];
}

- (void)lockBrowser {
  while (true) {
    std::string entered;
    if (!PromptSingleText(@"Unlock Browser", @"Enter master password.", @"Master password", true,
                          &entered)) {
      [_window close];
      return;
    }
    if (_profileStore->VerifyMasterPassword(_profileName, entered)) return;
    ShowError(@"Unlock Failed", @"Master password did not match.");
  }
}

- (void)createNewProfile {
  std::string profile;
  if (!PromptSingleText(@"Create Profile",
                        @"Enter new profile name (letters, numbers, '_' and '-').", @"profile",
                        false, &profile)) {
    return;
  }
  if (!_profileStore->CreateProfile(profile)) {
    ShowError(@"Profile", @"Failed to create profile. Name may be invalid.");
    return;
  }

  std::string p1;
  std::string p2;
  if (!PromptSingleText(@"Set Profile Password", @"Set master password for the new profile.",
                        @"At least 8 characters", true, &p1) ||
      !PromptSingleText(@"Confirm Password", @"Re-enter password.", @"At least 8 characters", true,
                        &p2)) {
    return;
  }
  if (p1 != p2 || !_profileStore->SetMasterPassword(profile, p1)) {
    ShowError(@"Profile", @"Could not set password for new profile.");
    return;
  }
  ShowInfo(@"Profile Created",
           [NSString stringWithFormat:@"Profile '%s' created.\nLaunch with --profile %s",
                                      profile.c_str(), profile.c_str()]);
}

- (void)toggleNotesPanelVisible:(BOOL)visible {
  _notesVisible = visible;
  _notesPanel.hidden = !visible;
  if (visible) {
    _notesWidthConstraint.constant =
        std::max(kNotesPanelMinWidth, std::min(kNotesPanelMaxWidth, _notesPreferredWidth));
  } else {
    _notesPreferredWidth = _notesWidthConstraint.constant;
    _notesWidthConstraint.constant = 0.0;
  }
  SetButtonIcon(_notesToggleButton, 0xF249, visible ? @"Hide Notes" : @"Show Notes", 12, true);
  [_window.contentView layoutSubtreeIfNeeded];
}

- (CGFloat)currentZoom {
  if (@available(macOS 11.0, *)) {
    return _webView.pageZoom;
  }
  return _webView.magnification;
}

- (void)setCurrentZoom:(CGFloat)zoom {
  const CGFloat clamped = std::max(kMinZoom, std::min(kMaxZoom, zoom));
  if (@available(macOS 11.0, *)) {
    _webView.pageZoom = clamped;
  } else {
    _webView.magnification = clamped;
  }
}

- (void)openAdditionalWindowWithUrl:(NSString*)url {
  PriFacieBrowserController* controller =
      [[PriFacieBrowserController alloc] initWithProfileStore:_profileStore
                                               profileName:_profileName
                                                sessionKey:_sessionKey];
  [ActiveControllers() addObject:controller];
  [controller showWindow];
  if (url.length > 0) {
    [controller loadURLString:url];
  } else {
    [controller loadURLString:ToNSString(_settings.home_page.empty() ? kDefaultHomePage : _settings.home_page)];
  }
}

- (void)openAdditionalTabWithUrl:(NSString*)url {
  PriFacieBrowserController* controller =
      [[PriFacieBrowserController alloc] initWithProfileStore:_profileStore
                                               profileName:_profileName
                                                sessionKey:_sessionKey];
  [ActiveControllers() addObject:controller];
  [_window addTabbedWindow:controller->_window ordered:NSWindowAbove];
  [controller showWindow];
  if (url.length > 0) {
    [controller loadURLString:url];
  } else {
    [controller loadURLString:ToNSString(_settings.home_page.empty() ? kDefaultHomePage : _settings.home_page)];
  }
}

- (void)onBack:(id)sender {
  (void)sender;
  if (_webView.canGoBack) [_webView goBack];
}

- (void)onForward:(id)sender {
  (void)sender;
  if (_webView.canGoForward) [_webView goForward];
}

- (void)onReload:(id)sender {
  (void)sender;
  [_webView reload];
}

- (void)onHome:(id)sender {
  (void)sender;
  [self loadURLString:ToNSString(_settings.home_page.empty() ? kDefaultHomePage : _settings.home_page)];
}

- (void)onGoClick:(id)sender {
  (void)sender;
  [self navigateFromAddressInput:_addressField.stringValue];
}

- (void)onAddressCommit:(id)sender {
  (void)sender;
  [self navigateFromAddressInput:_addressField.stringValue];
}

- (void)onNewWindow:(id)sender {
  (void)sender;
  [self openAdditionalWindowWithUrl:nil];
}

- (void)onNewTab:(id)sender {
  (void)sender;
  [self openAdditionalTabWithUrl:nil];
}

- (void)onToggleCurrentBookmark:(id)sender {
  (void)sender;
  [self toggleCurrentBookmark];
}

- (void)onBookmarksMenuButton:(id)sender {
  (void)sender;
  [self rebuildBookmarksMenu];
  [self showMenu:_bookmarksMenu fromButton:_bookmarksButton];
}

- (void)onHistoryMenuButton:(id)sender {
  (void)sender;
  [self rebuildHistoryMenu];
  [self showMenu:_historyMenu fromButton:_historyButton];
}

- (void)onToolsMenuButton:(id)sender {
  (void)sender;
  [self rebuildToolsMenu];
  [self showMenu:_toolsMenu fromButton:_toolsButton];
}

- (void)onProfileMenuButton:(id)sender {
  (void)sender;
  [self rebuildProfileMenu];
  [self showMenu:_profileMenu fromButton:_profileButton];
}

- (void)onToggleNotesPanel:(id)sender {
  (void)sender;
  if (_notesVisible) {
    [self persistNotesFromEditor];
    [self persistEncryptedBrowserData];
  }
  [self toggleNotesPanelVisible:!_notesVisible];
}

- (void)onLockBrowser:(id)sender {
  (void)sender;
  [self persistNotesFromEditor];
  [self persistEncryptedBrowserData];
  dispatch_semaphore_t sem = dispatch_semaphore_create(0);
  [self clearBrowsingDataSilent:YES completion:^{
    dispatch_semaphore_signal(sem);
  }];
  dispatch_semaphore_wait(sem, dispatch_time(DISPATCH_TIME_NOW, 2 * NSEC_PER_SEC));
  if (_currentServerTrust) {
    CFRelease(_currentServerTrust);
    _currentServerTrust = nullptr;
  }
  _currentServerHost = @"";
  [_webView loadHTMLString:@"<html><body style='font-family:-apple-system;padding:24px;'>"
                           "<h2>PriFacie Locked</h2>"
                           "<p>Session web data has been cleared from memory.</p>"
                           "</body></html>"
                baseURL:nil];
  [self lockBrowser];
  if (_window.visible) {
    [self loadURLString:ToNSString(_settings.home_page.empty() ? kDefaultHomePage : _settings.home_page)];
  }
}

- (void)onOpenUrlMenuItem:(id)sender {
  NSString* url = [sender representedObject];
  if (url.length == 0) return;
  [self loadURLString:url];
}

- (void)onClearHistory:(id)sender {
  (void)sender;
  _browserData->ClearHistory();
  [self persistEncryptedBrowserData];
  ShowInfo(@"History", @"Browsing history cleared from encrypted vault.");
}

- (void)onClearBookmarks:(id)sender {
  (void)sender;
  _browserData->ClearBookmarks();
  [self persistEncryptedBrowserData];
  [self updateBookmarkButtonState];
  ShowInfo(@"Bookmarks", @"All bookmarks cleared from encrypted vault.");
}

- (void)onToggleHttpsOnly:(id)sender {
  (void)sender;
  _settings.https_only = !_settings.https_only;
  [self applyPrivacySettings];
}

- (void)onToggleTrackers:(id)sender {
  (void)sender;
  _settings.block_trackers = !_settings.block_trackers;
  [self applyPrivacySettings];
}

- (void)onToggleThirdParty:(id)sender {
  (void)sender;
  _settings.block_third_party_cookies = !_settings.block_third_party_cookies;
  [self applyPrivacySettings];
}

- (void)onToggleJavascript:(id)sender {
  (void)sender;
  _settings.javascript_enabled = !_settings.javascript_enabled;
  [self applyPrivacySettings];
}

- (void)onToggleClearOnExit:(id)sender {
  (void)sender;
  _settings.clear_data_on_exit = !_settings.clear_data_on_exit;
  [self saveSettings];
}

- (void)onToggleDarkMode:(id)sender {
  (void)sender;
  _settings.dark_mode = !_settings.dark_mode;
  [self saveSettings];
  [self applyTheme];
}

- (void)onAboutPriFacie:(id)sender {
  (void)sender;
  ShowInfo(@"About PriFacie", ToNSString(kAboutText));
}

- (void)onViewSiteCertificate:(id)sender {
  (void)sender;
  NSURL* url = _webView.URL;
  if (!url || ![url.scheme.lowercaseString isEqualToString:@"https"]) {
    ShowInfo(@"Site Certificate", @"Certificate details are only available for HTTPS pages.");
    return;
  }
  if (!_currentServerTrust) {
    ShowInfo(@"Site Certificate", @"No certificate details are available yet. Reload the page and try again.");
    return;
  }

  CFErrorRef trust_error = nullptr;
  const bool trusted = SecTrustEvaluateWithError(_currentServerTrust, &trust_error);
  NSString* trust_error_text = @"";
  if (trust_error) {
    trust_error_text = (__bridge_transfer NSString*)CFErrorCopyDescription(trust_error);
    CFRelease(trust_error);
  }
  NSString* host = url.host ? url.host : _currentServerHost;
  NSString* details =
      ToNSString(BuildCertificateDetails(_currentServerTrust, host, trusted, trust_error_text));
  NSString* summary = [NSString stringWithFormat:@"%@\nHost: %@", trusted ? @"TLS trust: VALID"
                                                                          : @"TLS trust: FAILED",
                                                 host ? host : @""];
  ShowLargeTextDialog(@"Site Certificate", summary, details);
}

- (void)onSetCurrentPageAsHome:(id)sender {
  (void)sender;
  NSString* current = _webView.URL.absoluteString ? _webView.URL.absoluteString : @"";
  if (current.length == 0) {
    ShowError(@"Home Page", @"No active page URL to save as home page.");
    return;
  }
  _settings.home_page = ToStdString(current);
  [self saveSettings];
  ShowInfo(@"Home Page", [NSString stringWithFormat:@"Home page set to:\n%@", current]);
}

- (void)onSetHomePageUrl:(id)sender {
  (void)sender;
  std::string entered;
  if (!PromptSingleText(@"Set Home Page URL", @"Enter URL or domain for the home page.",
                        @"https://example.com", false, &entered)) {
    return;
  }
  const std::string resolved = ResolveNavigationUrl(_settings, ToNSString(entered));
  if (resolved.empty()) {
    ShowError(@"Home Page", @"Invalid home page URL.");
    return;
  }
  _settings.home_page = resolved;
  [self saveSettings];
  ShowInfo(@"Home Page", [NSString stringWithFormat:@"Home page set to:\n%s", resolved.c_str()]);
}

- (void)onResetHomePageDefault:(id)sender {
  (void)sender;
  _settings.home_page = kDefaultHomePage;
  [self saveSettings];
  ShowInfo(@"Home Page", [NSString stringWithFormat:@"Home page reset to:\n%s", kDefaultHomePage]);
}

- (void)onSelectSearchEngine:(id)sender {
  NSString* prefix = [sender representedObject];
  if (prefix.length == 0) return;
  _settings.search_engine = ToStdString(prefix);
  [self saveSettings];
  ShowInfo(@"Search Engine", [NSString stringWithFormat:@"Default search engine updated:\n%@", prefix]);
}

- (void)onExportBookmarks:(id)sender {
  (void)sender;
  NSSavePanel* panel = [NSSavePanel savePanel];
  panel.title = @"Export Bookmarks";
  panel.nameFieldStringValue = @"prifacie-bookmarks.html";
  if (@available(macOS 11.0, *)) {
    panel.allowedContentTypes = @[UTTypeHTML];
  } else {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
    panel.allowedFileTypes = @[@"html"];
#pragma clang diagnostic pop
  }
  if ([panel runModal] != NSModalResponseOK || !panel.URL) return;

  std::ofstream out(ToStdString(panel.URL.path), std::ios::trunc);
  if (!out.is_open()) {
    ShowError(@"Bookmarks", @"Failed to create export file.");
    return;
  }
  out << "<!DOCTYPE NETSCAPE-Bookmark-file-1>\n"
         "<META HTTP-EQUIV=\"Content-Type\" CONTENT=\"text/html; charset=UTF-8\">\n"
         "<TITLE>Bookmarks</TITLE>\n"
         "<H1>PriFacie Bookmarks</H1>\n"
         "<DL><p>\n";
  for (const auto& b : _browserData->Bookmarks()) {
    const std::string title = b.title.empty() ? b.url : b.title;
    out << "  <DT><A HREF=\"" << HtmlEscape(b.url) << "\" ADD_DATE=\"" << b.created_at << "\">"
        << HtmlEscape(title) << "</A>\n";
  }
  out << "</DL><p>\n";
  ShowInfo(@"Bookmarks", @"Bookmarks exported successfully.");
}

- (void)onImportBookmarks:(id)sender {
  (void)sender;
  NSOpenPanel* panel = [NSOpenPanel openPanel];
  panel.title = @"Import Bookmarks";
  if (@available(macOS 11.0, *)) {
    panel.allowedContentTypes = @[UTTypeHTML];
  } else {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
    panel.allowedFileTypes = @[@"html", @"htm"];
#pragma clang diagnostic pop
  }
  panel.allowsMultipleSelection = NO;
  if ([panel runModal] != NSModalResponseOK || panel.URLs.count == 0) return;

  const std::string path = ToStdString(panel.URLs.firstObject.path);
  std::ifstream in(path);
  if (!in.is_open()) {
    ShowError(@"Bookmarks", @"Failed to read selected file.");
    return;
  }
  const std::string content((std::istreambuf_iterator<char>(in)), std::istreambuf_iterator<char>());
  const std::regex anchor_re("<a\\b[^>]*href\\s*=\\s*\"([^\"]+)\"[^>]*>(.*?)</a>",
                             std::regex::icase);

  std::size_t imported = 0;
  for (auto it = std::sregex_iterator(content.begin(), content.end(), anchor_re);
       it != std::sregex_iterator(); ++it) {
    std::string url = HtmlUnescape((*it)[1].str());
    std::string title = HtmlUnescape(StripHtmlTags((*it)[2].str()));
    if (url.empty()) continue;
    if (title.empty()) title = url;
    _browserData->AddBookmark(url, title, NowEpochSeconds());
    ++imported;
  }
  [self persistEncryptedBrowserData];
  [self updateBookmarkButtonState];
  ShowInfo(@"Bookmarks", [NSString stringWithFormat:@"Imported %zu bookmark(s).", imported]);
}

- (void)onSaveCredentials:(id)sender {
  (void)sender;
  [self saveCredentialsForCurrentSite];
}

- (void)onAutofillCredentials:(id)sender {
  (void)sender;
  [self autofillCredentialsForCurrentSite];
}

- (void)onFindInPage:(id)sender {
  (void)sender;
  std::string query;
  if (!PromptSingleText(@"Find in Page", @"Enter text to find in current page.", @"Search text", false,
                        &query)) {
    return;
  }
  const std::string js =
      "(function(){const q='" + JsEscape(query) +
      "'; if(!q){return false;} return window.find(q,false,false,true,false,false,false);})();";
  [_webView evaluateJavaScript:ToNSString(js)
             completionHandler:^(id result, NSError* error) {
               if (error) return;
               if ([result respondsToSelector:@selector(boolValue)] && ![result boolValue]) {
                 ShowInfo(@"Find in Page", @"No match found.");
               }
             }];
}

- (void)onZoomIn:(id)sender {
  (void)sender;
  [self setCurrentZoom:[self currentZoom] + 0.1];
}

- (void)onZoomOut:(id)sender {
  (void)sender;
  [self setCurrentZoom:[self currentZoom] - 0.1];
}

- (void)onResetZoom:(id)sender {
  (void)sender;
  [self setCurrentZoom:1.0];
}

- (void)onClearNow:(id)sender {
  (void)sender;
  [self clearBrowsingDataSilent:NO completion:nil];
}

- (void)onPrint:(id)sender {
  (void)sender;
  NSPrintOperation* print_op = [_webView printOperationWithPrintInfo:[NSPrintInfo sharedPrintInfo]];
  [print_op runOperationModalForWindow:_window delegate:nil didRunSelector:nil contextInfo:nullptr];
}

- (void)onCreateProfile:(id)sender {
  (void)sender;
  [self createNewProfile];
}

- (void)onDeleteCurrentProfile:(id)sender {
  (void)sender;
  NSString* warning = [NSString stringWithFormat:
                                    @"Delete profile '%s' permanently?\n\nThis erases encrypted vault, saved passwords, history, bookmarks, notes, and all profile files.",
                                    _profileName.c_str()];
  if (!PromptDangerConfirm(@"Delete Profile", warning, @"Delete Permanently")) return;

  std::string typed_profile;
  if (!PromptSingleText(@"Delete Profile",
                        [NSString stringWithFormat:@"Type '%s' to confirm permanent deletion.",
                                                   _profileName.c_str()],
                        @"Profile name", false, &typed_profile)) {
    return;
  }
  if (typed_profile != _profileName) {
    ShowError(@"Delete Profile", @"Profile name confirmation did not match.");
    return;
  }

  std::string password;
  if (!PromptSingleText(@"Delete Profile", @"Enter master password to authorize deletion.",
                        @"Master password", true, &password)) {
    return;
  }
  if (!_profileStore->VerifyMasterPassword(_profileName, password)) {
    ShowError(@"Delete Profile", @"Master password is incorrect.");
    return;
  }

  [self persistNotesFromEditor];
  [self persistEncryptedBrowserData];
  dispatch_semaphore_t sem = dispatch_semaphore_create(0);
  [self clearBrowsingDataSilent:YES completion:^{
    dispatch_semaphore_signal(sem);
  }];
  dispatch_semaphore_wait(sem, dispatch_time(DISPATCH_TIME_NOW, 2 * NSEC_PER_SEC));

  if (!_profileStore->DeleteProfile(_profileName)) {
    ShowError(@"Delete Profile", @"Failed to erase profile files. Close other windows for this profile and try again.");
    return;
  }
  ShowInfo(@"Profile Deleted", @"Profile was permanently deleted and erased from disk.");
  [NSApp terminate:nil];
}

- (void)onClearNotes:(id)sender {
  (void)sender;
  _notesTextView.string = @"";
  _browserData->SetNotes("");
  [self persistEncryptedBrowserData];
}

- (void)onLoadNotesFromFile:(id)sender {
  (void)sender;
  NSOpenPanel* panel = [NSOpenPanel openPanel];
  panel.title = @"Load Notes";
  panel.allowsMultipleSelection = NO;
  panel.canChooseFiles = YES;
  panel.canChooseDirectories = NO;
  if (@available(macOS 11.0, *)) {
    panel.allowedContentTypes = @[UTTypePlainText];
  } else {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
    panel.allowedFileTypes = @[@"txt"];
#pragma clang diagnostic pop
  }
  if ([panel runModal] != NSModalResponseOK || panel.URLs.count == 0) return;

  NSURL* url = panel.URLs.firstObject;
  if (!url) return;

  NSError* error = nil;
  NSString* loaded_text = [NSString stringWithContentsOfURL:url
                                                   encoding:NSUTF8StringEncoding
                                                      error:&error];
  if (!loaded_text) {
    NSString* err = error.localizedDescription ? error.localizedDescription : @"Unknown error";
    ShowError(@"Notes", [NSString stringWithFormat:@"Could not load notes file.\n%@", err]);
    return;
  }

  if (!_notesVisible) {
    [self toggleNotesPanelVisible:YES];
  }
  _notesTextView.string = loaded_text;
  [self persistNotesFromEditor];
  [self persistEncryptedBrowserData];
  ShowInfo(@"Notes", @"Notes loaded successfully.");
}

- (void)onSaveNotesToFile:(id)sender {
  (void)sender;
  NSSavePanel* panel = [NSSavePanel savePanel];
  panel.title = @"Save Notes";
  panel.nameFieldStringValue = @"prifacie-notes.txt";
  if (@available(macOS 11.0, *)) {
    panel.allowedContentTypes = @[UTTypePlainText];
  } else {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
    panel.allowedFileTypes = @[@"txt"];
#pragma clang diagnostic pop
  }
  if ([panel runModal] != NSModalResponseOK || !panel.URL) return;
  NSString* notes_text = _notesTextView.string ? _notesTextView.string : @"";
  NSError* error = nil;
  if (![notes_text writeToURL:panel.URL atomically:YES encoding:NSUTF8StringEncoding error:&error]) {
    NSString* err = error.localizedDescription ? error.localizedDescription : @"Unknown error";
    ShowError(@"Notes", [NSString stringWithFormat:@"Could not save notes file.\n%@", err]);
    return;
  }
  ShowInfo(@"Notes", @"Notes exported successfully.");
}

- (void)textDidChange:(NSNotification*)notification {
  if (notification.object != _notesTextView) return;
  [self persistNotesFromEditor];
  [self persistEncryptedBrowserData];
}

- (BOOL)windowShouldClose:(NSWindow*)sender {
  if (!sender) return YES;
  if (@available(macOS 10.12, *)) {
    NSArray<NSWindow*>* tabs = sender.tabbedWindows;
    if (tabs.count > 1) {
      [sender moveTabToNewWindow:nil];
      dispatch_async(dispatch_get_main_queue(), ^{
        [sender performClose:nil];
      });
      return NO;
    }
  }
  return YES;
}

- (void)windowWillClose:(NSNotification*)notification {
  (void)notification;
  [ActiveControllers() removeObject:self];
  if (_keyMonitor) {
    [NSEvent removeMonitor:_keyMonitor];
    _keyMonitor = nil;
  }
  if (_observingWebView) {
    @try {
      [_webView removeObserver:self forKeyPath:@"estimatedProgress"];
    } @catch (__unused NSException* e) {
    }
    _observingWebView = false;
  }
  [_engineAdapter shutdown];
  if (_webView) {
    [_webView.configuration.userContentController
        removeScriptMessageHandlerForName:ToNSString(kDownloadsMessageHandler)];
  }
  if (_downloadSession) {
    [_downloadSession invalidateAndCancel];
    _downloadSession = nil;
  }
  if (_currentServerTrust) {
    CFRelease(_currentServerTrust);
    _currentServerTrust = nullptr;
  }
  _currentServerHost = @"";

  [self persistNotesFromEditor];
  [self persistEncryptedBrowserData];
  [self saveSettings];

  if (_settings.clear_data_on_exit) {
    dispatch_semaphore_t sem = dispatch_semaphore_create(0);
    [self clearBrowsingDataSilent:YES completion:^{
      dispatch_semaphore_signal(sem);
    }];
    dispatch_semaphore_wait(sem, dispatch_time(DISPATCH_TIME_NOW, 2 * NSEC_PER_SEC));
  }

  SecureWipe(&_sessionKey);
}

- (void)webView:(WKWebView*)webView
didReceiveAuthenticationChallenge:(NSURLAuthenticationChallenge*)challenge
completionHandler:(void (^)(NSURLSessionAuthChallengeDisposition, NSURLCredential*))completionHandler {
  (void)webView;
  if (!challenge || !completionHandler) return;
  if ([challenge.protectionSpace.authenticationMethod isEqualToString:NSURLAuthenticationMethodServerTrust]) {
    SecTrustRef trust = challenge.protectionSpace.serverTrust;
    if (trust) {
      CFRetain(trust);
      if (_currentServerTrust) CFRelease(_currentServerTrust);
      _currentServerTrust = trust;
      _currentServerHost = challenge.protectionSpace.host ? challenge.protectionSpace.host : @"";
      completionHandler(NSURLSessionAuthChallengeUseCredential, [NSURLCredential credentialForTrust:trust]);
      return;
    }
  }
  completionHandler(NSURLSessionAuthChallengePerformDefaultHandling, nil);
}

- (void)webView:(WKWebView*)webView
    decidePolicyForNavigationAction:(WKNavigationAction*)navigationAction
                        preferences:(WKWebpagePreferences*)preferences
                    decisionHandler:(void (^)(WKNavigationActionPolicy, WKWebpagePreferences*))decisionHandler {
  NSURL* url = navigationAction.request.URL;
  [self appendDevLog:[NSString stringWithFormat:@"[NAV] %@", url.absoluteString ? url.absoluteString : @""]];

  if (@available(macOS 11.3, *)) {
    if (navigationAction.shouldPerformDownload && url) {
      [self queueDownloadFromURL:url suggestedFilename:navigationAction.request.URL.lastPathComponent];
      decisionHandler(WKNavigationActionPolicyCancel, preferences);
      return;
    }
  }

  if (url && navigationAction.navigationType == WKNavigationTypeLinkActivated && IsLikelyDownloadUrl(url)) {
    [self queueDownloadFromURL:url suggestedFilename:navigationAction.request.URL.lastPathComponent];
    decisionHandler(WKNavigationActionPolicyCancel, preferences);
    return;
  }

  if (_settings.https_only && [url.scheme.lowercaseString isEqualToString:@"http"]) {
    NSURLComponents* comp = [NSURLComponents componentsWithURL:url resolvingAgainstBaseURL:NO];
    comp.scheme = @"https";
    NSURL* upgraded = comp.URL;
    if (upgraded) {
      [webView loadRequest:[NSURLRequest requestWithURL:upgraded]];
      decisionHandler(WKNavigationActionPolicyCancel, preferences);
      return;
    }
  }

  preferences.allowsContentJavaScript = _settings.javascript_enabled;
  if (@available(macOS 15.2, *)) {
    preferences.preferredHTTPSNavigationPolicy =
        _settings.https_only ? WKWebpagePreferencesUpgradeToHTTPSPolicyErrorOnFailure
                             : WKWebpagePreferencesUpgradeToHTTPSPolicyKeepAsRequested;
  }
  decisionHandler(WKNavigationActionPolicyAllow, preferences);
}

- (void)webView:(WKWebView*)webView
    decidePolicyForNavigationResponse:(WKNavigationResponse*)navigationResponse
                      decisionHandler:(void (^)(WKNavigationResponsePolicy))decisionHandler {
  (void)webView;
  NSURLResponse* response = navigationResponse.response;
  bool should_download = false;
  if ([response isKindOfClass:[NSHTTPURLResponse class]]) {
    NSHTTPURLResponse* http = (NSHTTPURLResponse*)response;
    NSString* disposition = nil;
    for (id key in http.allHeaderFields) {
      if (![key isKindOfClass:[NSString class]]) continue;
      NSString* key_text = [(NSString*)key lowercaseString];
      if ([key_text isEqualToString:@"content-disposition"]) {
        id value = http.allHeaderFields[key];
        if ([value isKindOfClass:[NSString class]]) disposition = (NSString*)value;
        break;
      }
    }
    should_download = disposition && [disposition.lowercaseString containsString:@"attachment"];
  }

  if (should_download && response.URL) {
    [self queueDownloadFromURL:response.URL suggestedFilename:response.suggestedFilename];
    decisionHandler(WKNavigationResponsePolicyCancel);
    return;
  }
  decisionHandler(WKNavigationResponsePolicyAllow);
}

- (void)webView:(WKWebView*)webView didStartProvisionalNavigation:(WKNavigation*)navigation {
  (void)webView;
  (void)navigation;
  [self appendDevLog:@"[LOAD] Started"];
  [self updateAddressSecurityAndNav];
}

- (void)webView:(WKWebView*)webView didFinishNavigation:(WKNavigation*)navigation {
  (void)webView;
  (void)navigation;
  [self updateAddressSecurityAndNav];
  [self updateBookmarkButtonState];
  [self recordCurrentPageInHistory];
  [self appendDevLog:@"[LOAD] Finished"];

  NSString* title = _webView.title ? _webView.title : @"PriFacie";
  _window.title = [NSString stringWithFormat:@"PriFacie - %@", title];
}

- (void)webView:(WKWebView*)webView didFailNavigation:(WKNavigation*)navigation withError:(NSError*)error {
  (void)webView;
  (void)navigation;
  [self appendDevLog:[NSString stringWithFormat:@"[LOAD ERROR] %@",
                                               error.localizedDescription ? error.localizedDescription : @"Unknown"]];
  [self updateAddressSecurityAndNav];
}

- (void)URLSession:(NSURLSession*)session
      downloadTask:(NSURLSessionDownloadTask*)downloadTask
 didWriteData:(int64_t)bytesWritten
 totalBytesWritten:(int64_t)totalBytesWritten
 totalBytesExpectedToWrite:(int64_t)totalBytesExpectedToWrite {
  (void)session;
  (void)bytesWritten;
  const int item_id = (int)downloadTask.taskDescription.integerValue;
  DownloadItem* item = [self downloadItemById:item_id];
  if (!item) return;
  item->received_bytes = totalBytesWritten;
  item->total_bytes = totalBytesExpectedToWrite;
}

- (void)URLSession:(NSURLSession*)session
      downloadTask:(NSURLSessionDownloadTask*)downloadTask
 didFinishDownloadingToURL:(NSURL*)location {
  (void)session;
  const int item_id = (int)downloadTask.taskDescription.integerValue;
  DownloadItem* item = [self downloadItemById:item_id];
  if (!item) return;

  NSString* folder = [self resolvedDownloadTargetFolderPath];
  NSString* preferred =
      [self suggestedFilenameForURL:[NSURL URLWithString:ToNSString(item->url)]
                            explicit:downloadTask.response.suggestedFilename];
  NSString* destination = [self uniqueDestinationPathForFilename:preferred inFolder:folder];
  NSURL* destination_url = [NSURL fileURLWithPath:destination];
  NSError* move_error = nil;
  [[NSFileManager defaultManager] removeItemAtURL:destination_url error:nil];
  if (![[NSFileManager defaultManager] moveItemAtURL:location toURL:destination_url error:&move_error]) {
    item->status = "failed";
    item->error_text = ToStdString(move_error.localizedDescription ? move_error.localizedDescription : @"Move failed");
    NSString* move_text = move_error.localizedDescription ? move_error.localizedDescription : @"Move failed";
    [self appendDevLog:[NSString stringWithFormat:@"[DOWNLOAD ERROR] %@", move_text]];
  } else {
    item->status = "completed";
    item->saved_path = ToStdString(destination);
    item->error_text.clear();
    item->total_bytes = std::max(item->total_bytes, item->received_bytes);
    [self appendDevLog:[NSString stringWithFormat:@"[DOWNLOAD DONE] %@", destination]];
  }
}

- (void)URLSession:(NSURLSession*)session task:(NSURLSessionTask*)task didCompleteWithError:(NSError*)error {
  (void)session;
  const int item_id = (int)task.taskDescription.integerValue;
  [_activeDownloadTasks removeObjectForKey:@(item_id)];

  DownloadItem* item = [self downloadItemById:item_id];
  if (!item) {
    [self refreshDownloadsManagerIfVisible];
    return;
  }

  if (!error) {
    if (item->status == "downloading") item->status = "completed";
    [self refreshDownloadsManagerIfVisible];
    return;
  }

  if (item->status == "paused") {
    NSData* resume_data = error.userInfo[NSURLSessionDownloadTaskResumeData];
    if (resume_data) item->resume_data = ToByteVector(resume_data);
    [self refreshDownloadsManagerIfVisible];
    return;
  }

  item->status = "failed";
  item->error_text = ToStdString(error.localizedDescription ? error.localizedDescription : @"Download failed");
  NSData* resume_data = error.userInfo[NSURLSessionDownloadTaskResumeData];
  if (resume_data) item->resume_data = ToByteVector(resume_data);
  NSString* error_text = error.localizedDescription ? error.localizedDescription : @"Download failed";
  [self appendDevLog:[NSString stringWithFormat:@"[DOWNLOAD ERROR] %@", error_text]];
  [self refreshDownloadsManagerIfVisible];
}

- (void)userContentController:(WKUserContentController*)userContentController
      didReceiveScriptMessage:(WKScriptMessage*)message {
  (void)userContentController;
  if ([message.name isEqualToString:ToNSString(kDownloadsMessageHandler)]) {
    NSString* action = @"";
    NSString* url_text = @"";
    NSInteger item_id = 0;
    if ([message.body isKindOfClass:[NSDictionary class]]) {
      NSDictionary* dict = (NSDictionary*)message.body;
      if ([dict[@"action"] isKindOfClass:[NSString class]]) action = dict[@"action"];
      if ([dict[@"id"] respondsToSelector:@selector(integerValue)]) item_id = [dict[@"id"] integerValue];
      if ([dict[@"url"] isKindOfClass:[NSString class]]) url_text = dict[@"url"];
    }
    if ([action isEqualToString:@"refresh"]) {
      [self refreshDownloadsManagerIfVisible];
    } else if ([action isEqualToString:@"pause"]) {
      [self pauseDownloadById:(int)item_id];
    } else if ([action isEqualToString:@"resume"]) {
      [self resumeDownloadById:(int)item_id];
    } else if ([action isEqualToString:@"start"]) {
      [self startDownloadById:(int)item_id];
    } else if ([action isEqualToString:@"choose-folder"]) {
      [self onChooseDownloadFolder:nil];
    } else if ([action isEqualToString:@"open-folder"]) {
      [[NSWorkspace sharedWorkspace] openURL:[NSURL fileURLWithPath:[self resolvedDownloadTargetFolderPath]]];
    } else if ([action isEqualToString:@"show-item"]) {
      DownloadItem* item = [self downloadItemById:(int)item_id];
      if (item && !item->saved_path.empty()) {
        [[NSWorkspace sharedWorkspace] activateFileViewerSelectingURLs:@[
          [NSURL fileURLWithPath:ToNSString(item->saved_path)]
        ]];
      }
    } else if ([action isEqualToString:@"download-url"]) {
      [self enqueueDownloadFromInputText:url_text];
    }
    return;
  }

  if (![message.name isEqualToString:@"prifacie_devlog"]) return;

  NSString* level = @"log";
  NSString* text = @"";
  if ([message.body isKindOfClass:[NSDictionary class]]) {
    NSDictionary* dict = (NSDictionary*)message.body;
    if ([dict[@"level"] isKindOfClass:[NSString class]]) level = dict[@"level"];
    if ([dict[@"text"] isKindOfClass:[NSString class]]) text = dict[@"text"];
  } else if ([message.body isKindOfClass:[NSString class]]) {
    text = (NSString*)message.body;
  } else if (message.body) {
    text = [NSString stringWithFormat:@"%@", message.body];
  }
  [self appendDevLog:[NSString stringWithFormat:@"[CONSOLE/%@] %@", level.uppercaseString, text]];
}

@end

@interface PriFacieAppDelegate : NSObject <NSApplicationDelegate>
@property(nonatomic, strong) PriFacieBrowserController* controller;
@end

@implementation PriFacieAppDelegate
- (instancetype)initWithController:(PriFacieBrowserController*)controller {
  self = [super init];
  if (!self) return nil;
  _controller = controller;
  return self;
}

- (PriFacieBrowserController*)activeController {
  PriFacieBrowserController* active = ActiveControllerForWindow(NSApp.keyWindow);
  return active ? active : self.controller;
}

- (NSMenuItem*)addMenuItemTo:(NSMenu*)menu
                       title:(NSString*)title
                      action:(SEL)action
               keyEquivalent:(NSString*)key
               modifierFlags:(NSEventModifierFlags)flags {
  NSMenuItem* item =
      [[NSMenuItem alloc] initWithTitle:title action:action keyEquivalent:(key ? key : @"")];
  item.target = self;
  if (key.length > 0) item.keyEquivalentModifierMask = flags;
  [menu addItem:item];
  return item;
}

- (void)buildMainMenu {
  NSMenu* menubar = [[NSMenu alloc] initWithTitle:@""];

  NSMenuItem* appRoot = [[NSMenuItem alloc] initWithTitle:@"PriFacie" action:nil keyEquivalent:@""];
  [menubar addItem:appRoot];
  NSMenu* appMenu = [[NSMenu alloc] initWithTitle:@"PriFacie"];
  [self addMenuItemTo:appMenu title:@"About PriFacie" action:@selector(onMenuAbout:) keyEquivalent:@"" modifierFlags:0];
  [appMenu addItem:[NSMenuItem separatorItem]];
  [self addMenuItemTo:appMenu
                title:@"Quit PriFacie"
               action:@selector(onMenuQuit:)
        keyEquivalent:@"q"
        modifierFlags:NSEventModifierFlagCommand];
  [menubar setSubmenu:appMenu forItem:appRoot];

  NSMenuItem* fileRoot = [[NSMenuItem alloc] initWithTitle:@"File" action:nil keyEquivalent:@""];
  [menubar addItem:fileRoot];
  NSMenu* fileMenu = [[NSMenu alloc] initWithTitle:@"File"];
  [self addMenuItemTo:fileMenu
                title:@"New Tab"
               action:@selector(onMenuNewTab:)
        keyEquivalent:@"t"
        modifierFlags:NSEventModifierFlagControl];
  [self addMenuItemTo:fileMenu
                title:@"New Window"
               action:@selector(onMenuNewWindow:)
        keyEquivalent:@"n"
        modifierFlags:NSEventModifierFlagControl];
  [fileMenu addItem:[NSMenuItem separatorItem]];
  [self addMenuItemTo:fileMenu
                title:@"Open Location..."
               action:@selector(onMenuOpenLocation:)
        keyEquivalent:@"l"
        modifierFlags:NSEventModifierFlagControl];
  [self addMenuItemTo:fileMenu
                title:@"Open File..."
               action:@selector(onMenuOpenFile:)
        keyEquivalent:@"o"
        modifierFlags:NSEventModifierFlagControl];
  [self addMenuItemTo:fileMenu
                title:@"Load Notes..."
               action:@selector(onMenuLoadNotes:)
        keyEquivalent:@""
        modifierFlags:0];
  [self addMenuItemTo:fileMenu
                title:@"Save Notes..."
               action:@selector(onMenuSaveNotes:)
        keyEquivalent:@""
        modifierFlags:0];
  [self addMenuItemTo:fileMenu
                title:@"Downloads Manager Tab"
               action:@selector(onMenuDownloadsTab:)
        keyEquivalent:@"j"
        modifierFlags:NSEventModifierFlagCommand];
  [self addMenuItemTo:fileMenu
                title:@"Select Downloads Folder..."
               action:@selector(onMenuSelectDownloadsFolder:)
        keyEquivalent:@""
        modifierFlags:0];
  [self addMenuItemTo:fileMenu
                title:@"Download From URL..."
               action:@selector(onMenuDownloadFromURL:)
        keyEquivalent:@""
        modifierFlags:0];
  [fileMenu addItem:[NSMenuItem separatorItem]];
  [self addMenuItemTo:fileMenu
                title:@"Close Window"
               action:@selector(onMenuCloseWindow:)
        keyEquivalent:@"w"
        modifierFlags:NSEventModifierFlagControl];
  [menubar setSubmenu:fileMenu forItem:fileRoot];

  NSMenuItem* editRoot = [[NSMenuItem alloc] initWithTitle:@"Edit" action:nil keyEquivalent:@""];
  [menubar addItem:editRoot];
  NSMenu* editMenu = [[NSMenu alloc] initWithTitle:@"Edit"];
  NSMenuItem* undo = [[NSMenuItem alloc] initWithTitle:@"Undo" action:@selector(undo:) keyEquivalent:@"z"];
  undo.keyEquivalentModifierMask = NSEventModifierFlagCommand;
  [editMenu addItem:undo];
  NSMenuItem* redo =
      [[NSMenuItem alloc] initWithTitle:@"Redo" action:@selector(redo:) keyEquivalent:@"Z"];
  redo.keyEquivalentModifierMask = NSEventModifierFlagCommand;
  [editMenu addItem:redo];
  [editMenu addItem:[NSMenuItem separatorItem]];
  NSMenuItem* cut = [[NSMenuItem alloc] initWithTitle:@"Cut" action:@selector(cut:) keyEquivalent:@"x"];
  cut.keyEquivalentModifierMask = NSEventModifierFlagCommand;
  [editMenu addItem:cut];
  NSMenuItem* copy = [[NSMenuItem alloc] initWithTitle:@"Copy" action:@selector(copy:) keyEquivalent:@"c"];
  copy.keyEquivalentModifierMask = NSEventModifierFlagCommand;
  [editMenu addItem:copy];
  NSMenuItem* paste = [[NSMenuItem alloc] initWithTitle:@"Paste" action:@selector(paste:) keyEquivalent:@"v"];
  paste.keyEquivalentModifierMask = NSEventModifierFlagCommand;
  [editMenu addItem:paste];
  NSMenuItem* selectAll =
      [[NSMenuItem alloc] initWithTitle:@"Select All" action:@selector(selectAll:) keyEquivalent:@"a"];
  selectAll.keyEquivalentModifierMask = NSEventModifierFlagCommand;
  [editMenu addItem:selectAll];
  [menubar setSubmenu:editMenu forItem:editRoot];

  NSMenuItem* devRoot = [[NSMenuItem alloc] initWithTitle:@"Developer" action:nil keyEquivalent:@""];
  [menubar addItem:devRoot];
  NSMenu* devMenu = [[NSMenu alloc] initWithTitle:@"Developer"];
  [self addMenuItemTo:devMenu
                title:@"Toggle Dev Panel"
               action:@selector(onMenuToggleDevPanel:)
        keyEquivalent:@"d"
        modifierFlags:NSEventModifierFlagControl];
  [self addMenuItemTo:devMenu
                title:@"View Site Certificate"
               action:@selector(onMenuViewSiteCertificate:)
        keyEquivalent:@"c"
        modifierFlags:(NSEventModifierFlagControl | NSEventModifierFlagShift)];
  [self addMenuItemTo:devMenu
                title:@"Run JavaScript"
               action:@selector(onMenuRunDevScript:)
        keyEquivalent:@"j"
        modifierFlags:NSEventModifierFlagControl];
  [self addMenuItemTo:devMenu title:@"Page Source Snapshot"
               action:@selector(onMenuPageSource:) keyEquivalent:@"" modifierFlags:0];
  [self addMenuItemTo:devMenu title:@"Website Data Summary"
               action:@selector(onMenuWebsiteData:) keyEquivalent:@"" modifierFlags:0];
  [self addMenuItemTo:devMenu title:@"Clear Dev Logs"
               action:@selector(onMenuClearDevLogs:) keyEquivalent:@"" modifierFlags:0];
  [menubar setSubmenu:devMenu forItem:devRoot];

  NSApp.mainMenu = menubar;
}

- (void)onMenuAbout:(id)sender {
  (void)sender;
  [[self activeController] onAboutPriFacie:nil];
}

- (void)onMenuQuit:(id)sender {
  (void)sender;
  [NSApp terminate:nil];
}

- (void)onMenuNewTab:(id)sender {
  (void)sender;
  [[self activeController] onNewTab:nil];
}

- (void)onMenuNewWindow:(id)sender {
  (void)sender;
  [[self activeController] onNewWindow:nil];
}

- (void)onMenuOpenLocation:(id)sender {
  (void)sender;
  [[self activeController] onOpenLocationPrompt:nil];
}

- (void)onMenuOpenFile:(id)sender {
  (void)sender;
  [[self activeController] onOpenFile:nil];
}

- (void)onMenuLoadNotes:(id)sender {
  (void)sender;
  [[self activeController] onLoadNotesFromFile:nil];
}

- (void)onMenuSaveNotes:(id)sender {
  (void)sender;
  [[self activeController] onSaveNotesToFile:nil];
}

- (void)onMenuDownloadsTab:(id)sender {
  (void)sender;
  [[self activeController] onOpenDownloadsManagerTab:nil];
}

- (void)onMenuSelectDownloadsFolder:(id)sender {
  (void)sender;
  [[self activeController] onChooseDownloadFolder:nil];
}

- (void)onMenuDownloadFromURL:(id)sender {
  (void)sender;
  [[self activeController] onDownloadFromUrlPrompt:nil];
}

- (void)onMenuCloseWindow:(id)sender {
  (void)sender;
  [[self activeController] onCloseWindow:nil];
}

- (void)onMenuToggleDevPanel:(id)sender {
  (void)sender;
  [[self activeController] onToggleDevPanel:nil];
}

- (void)onMenuViewSiteCertificate:(id)sender {
  (void)sender;
  [[self activeController] onViewSiteCertificate:nil];
}

- (void)onMenuRunDevScript:(id)sender {
  (void)sender;
  [[self activeController] onRunDevScript:nil];
}

- (void)onMenuPageSource:(id)sender {
  (void)sender;
  [[self activeController] onLoadPageSource:nil];
}

- (void)onMenuWebsiteData:(id)sender {
  (void)sender;
  [[self activeController] onDumpWebsiteDataSummary:nil];
}

- (void)onMenuClearDevLogs:(id)sender {
  (void)sender;
  [[self activeController] onClearDevLogs:nil];
}

- (void)applicationDidFinishLaunching:(NSNotification*)notification {
  (void)notification;
  [self buildMainMenu];
  [self.controller showWindow];
}

- (BOOL)applicationShouldTerminateAfterLastWindowClosed:(NSApplication*)sender {
  (void)sender;
  return YES;
}
@end

int RunBrowserApp(ProfileStore* profile_store,
                  const std::string& profile_name,
                  const std::vector<unsigned char>& session_key) {
  @autoreleasepool {
    NSApplication* app = [NSApplication sharedApplication];
    ApplyPriFacieIconImage();
    [app setActivationPolicy:NSApplicationActivationPolicyRegular];
    [NSWindow setAllowsAutomaticWindowTabbing:YES];

    PriFacieBrowserController* controller =
        [[PriFacieBrowserController alloc] initWithProfileStore:profile_store
                                                 profileName:profile_name
                                                  sessionKey:session_key];
    [ActiveControllers() addObject:controller];
    PriFacieAppDelegate* delegate = [[PriFacieAppDelegate alloc] initWithController:controller];
    app.delegate = delegate;
    [app activateIgnoringOtherApps:YES];
    [app run];
  }
  return 0;
}
