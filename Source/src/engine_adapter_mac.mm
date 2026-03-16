#import "engine_adapter_mac.h"

#include <algorithm>
#include <cctype>
#include <cstdio>
#include <cstdlib>
#include <sstream>

namespace {

constexpr const char* kDevLogMessageHandlerName = "prifacie_devlog";

NSString* ToNSString(const std::string& value) {
  NSString* converted = [[NSString alloc] initWithBytes:value.data()
                                                 length:value.size()
                                               encoding:NSUTF8StringEncoding];
  return converted ? converted : @"";
}

std::string ToLower(std::string value) {
  std::transform(value.begin(), value.end(), value.begin(), [](unsigned char c) {
    return static_cast<char>(std::tolower(c));
  });
  return value;
}

std::string RegexEscape(const std::string& input) {
  std::string out;
  out.reserve(input.size() * 2);
  for (char c : input) {
    if (c == '.' || c == '+' || c == '*' || c == '?' || c == '^' || c == '$' || c == '(' ||
        c == ')' || c == '[' || c == ']' || c == '{' || c == '}' || c == '|' || c == '\\') {
      out.push_back('\\');
    }
    out.push_back(c);
  }
  return out;
}

std::string JsonEscape(const std::string& value) {
  std::string out;
  out.reserve(value.size() * 2);
  for (unsigned char c : value) {
    switch (c) {
      case '\\':
        out += "\\\\";
        break;
      case '"':
        out += "\\\"";
        break;
      case '\b':
        out += "\\b";
        break;
      case '\f':
        out += "\\f";
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
        if (c < 0x20) {
          char buf[7];
          std::snprintf(buf, sizeof(buf), "\\u%04x", c);
          out += buf;
        } else {
          out.push_back(static_cast<char>(c));
        }
        break;
    }
  }
  return out;
}

}  // namespace

PriFacieEngineBackend ResolveEngineBackendFromEnvironment() {
  const char* raw = std::getenv("PRIFACIE_ENGINE_BACKEND");
  if (!raw) return PriFacieEngineBackendWebKit;
  std::string value = ToLower(raw);
  if (value == "gecko" || value == "mozilla") return PriFacieEngineBackendGecko;
  return PriFacieEngineBackendWebKit;
}

NSString* PriFacieEngineBackendDisplayName(PriFacieEngineBackend backend) {
  switch (backend) {
    case PriFacieEngineBackendGecko:
      return @"Mozilla Gecko (Stub)";
    case PriFacieEngineBackendWebKit:
    default:
      return @"WebKit (Compat)";
  }
}

@interface PriFacieEngineAdapter ()
@property(nonatomic, readwrite) BOOL webDataEphemeral;
@property(nonatomic, strong) WKWebView* webKitView;
@property(nonatomic, strong) NSView* placeholderView;
@end

@implementation PriFacieEngineAdapter

- (instancetype)initWithBackend:(PriFacieEngineBackend)backend {
  self = [super init];
  if (!self) return nil;
  _backend = backend;
  _webDataEphemeral = NO;
  return self;
}

- (NSString*)engineDisplayName {
  return PriFacieEngineBackendDisplayName(self.backend);
}

- (NSView*)contentView {
  if (self.backend == PriFacieEngineBackendWebKit) return self.webKitView;
  return self.placeholderView;
}

- (WKWebView*)webView {
  return self.webKitView;
}

- (void)ensureGeckoPlaceholder {
  if (self.placeholderView) return;

  NSView* container = [[NSView alloc] initWithFrame:NSZeroRect];
  container.wantsLayer = YES;
  container.layer.backgroundColor = [[NSColor colorWithCalibratedRed:0.95 green:0.96 blue:0.98 alpha:1.0] CGColor];

  NSTextField* title = [NSTextField labelWithString:@"Gecko Backend Selected"];
  title.translatesAutoresizingMaskIntoConstraints = NO;
  title.font = [NSFont boldSystemFontOfSize:20];
  title.textColor = NSColor.labelColor;
  [container addSubview:title];

  NSTextField* message = [NSTextField
      labelWithString:
          @"This build includes full app wiring, but Gecko runtime embedding is not available on macOS in this codebase."];
  message.translatesAutoresizingMaskIntoConstraints = NO;
  message.maximumNumberOfLines = 3;
  message.lineBreakMode = NSLineBreakByWordWrapping;
  message.alignment = NSTextAlignmentCenter;
  message.font = [NSFont systemFontOfSize:14];
  message.textColor = NSColor.secondaryLabelColor;
  [container addSubview:message];

  [NSLayoutConstraint activateConstraints:@[
    [title.centerXAnchor constraintEqualToAnchor:container.centerXAnchor],
    [title.centerYAnchor constraintEqualToAnchor:container.centerYAnchor constant:-16],
    [message.topAnchor constraintEqualToAnchor:title.bottomAnchor constant:10],
    [message.centerXAnchor constraintEqualToAnchor:container.centerXAnchor],
    [message.widthAnchor constraintLessThanOrEqualToAnchor:container.widthAnchor multiplier:0.8],
  ]];

  self.placeholderView = container;
  self.webDataEphemeral = NO;
}

- (void)initializeEngineWithProfileStore:(ProfileStore*)profileStore
                             profileName:(const std::string&)profileName
                                settings:(const BrowserSettings&)settings
                           messageTarget:(id<WKScriptMessageHandler>)messageTarget
                      navigationDelegate:(id<WKNavigationDelegate>)navigationDelegate
                              uiDelegate:(id<WKUIDelegate>)uiDelegate {
  if (self.backend == PriFacieEngineBackendGecko) {
    [self ensureGeckoPlaceholder];
    self.webKitView = nil;
    return;
  }

  WKWebsiteDataStore* dataStore = [WKWebsiteDataStore nonPersistentDataStore];
  self.webDataEphemeral = YES;

  NSSet<NSString*>* websiteTypes = [WKWebsiteDataStore allWebsiteDataTypes];
  NSDate* epoch = [NSDate dateWithTimeIntervalSince1970:0];
  [[WKWebsiteDataStore defaultDataStore] removeDataOfTypes:websiteTypes
                                              modifiedSince:epoch
                                          completionHandler:^{}];

  std::string legacyUuid;
  if (profileStore && profileStore->GetOrCreateEngineDataStoreId(profileName, &legacyUuid)) {
    NSUUID* identifier = [[NSUUID alloc] initWithUUIDString:ToNSString(legacyUuid)];
    if (identifier) {
      WKWebsiteDataStore* legacyStore = [WKWebsiteDataStore dataStoreForIdentifier:identifier];
      [legacyStore removeDataOfTypes:websiteTypes modifiedSince:epoch completionHandler:^{}];
    }
  }

  WKWebViewConfiguration* config = [[WKWebViewConfiguration alloc] init];
  config.websiteDataStore = dataStore;
  config.userContentController = [[WKUserContentController alloc] init];
  [config.userContentController addScriptMessageHandler:messageTarget
                                                   name:@(kDevLogMessageHandlerName)];

  NSString* devHookJs =
      @"(function(){"
       "if(window.__prifacieDevHook){return;}window.__prifacieDevHook=true;"
       "function toText(v){if(typeof v==='string')return v;try{return JSON.stringify(v);}catch(_){return String(v);}}"
       "function send(level,args){try{var text=Array.prototype.slice.call(args).map(toText).join(' ');"
       "var bridge=(window.gecko&&window.gecko.messageHandlers)?window.gecko:window.webkit;"
       "if(!bridge||!bridge.messageHandlers||!bridge.messageHandlers.prifacie_devlog){return;}"
       "bridge.messageHandlers.prifacie_devlog.postMessage({level:level,text:text});}catch(_){}}"
       "['log','warn','error','info','debug'].forEach(function(level){"
       "if(!console[level]){return;}var orig=console[level].bind(console);"
       "console[level]=function(){send(level,arguments);return orig.apply(console,arguments);};});"
       "window.addEventListener('error',function(e){send('error',[e.message||'Script error',e.filename||'',e.lineno||0]);});"
       "window.addEventListener('unhandledrejection',function(e){send('error',['Unhandled promise rejection',e.reason]);});"
       "})();";
  WKUserScript* devScript = [[WKUserScript alloc] initWithSource:devHookJs
                                                    injectionTime:WKUserScriptInjectionTimeAtDocumentStart
                                                 forMainFrameOnly:NO];
  [config.userContentController addUserScript:devScript];
  config.defaultWebpagePreferences.allowsContentJavaScript = settings.javascript_enabled;
  if (@available(macOS 15.2, *)) {
    config.defaultWebpagePreferences.preferredHTTPSNavigationPolicy =
        settings.https_only ? WKWebpagePreferencesUpgradeToHTTPSPolicyErrorOnFailure
                            : WKWebpagePreferencesUpgradeToHTTPSPolicyKeepAsRequested;
  }

  WKWebView* view = [[WKWebView alloc] initWithFrame:NSZeroRect configuration:config];
  view.translatesAutoresizingMaskIntoConstraints = NO;
  view.navigationDelegate = navigationDelegate;
  view.UIDelegate = uiDelegate;
  view.allowsBackForwardNavigationGestures = YES;
  self.webKitView = view;
}

- (void)compileRuleListWithIdentifier:(NSString*)identifier
                            rulesJson:(NSString*)rulesJson
                           controller:(WKUserContentController*)controller {
  if (!identifier || !controller || rulesJson.length == 0) return;
  [[WKContentRuleListStore defaultStore]
      compileContentRuleListForIdentifier:identifier
                   encodedContentRuleList:rulesJson
                        completionHandler:^(WKContentRuleList* list, NSError* error) {
                          if (error || !list) return;
                          [controller addContentRuleList:list];
                        }];
}

- (void)applyPrivacySettings:(const BrowserSettings&)settings
              trackerDomains:(const std::vector<std::string>&)trackerDomains {
  if (!self.webKitView) return;

  self.webKitView.configuration.defaultWebpagePreferences.allowsContentJavaScript =
      settings.javascript_enabled;
  if (@available(macOS 15.2, *)) {
    self.webKitView.configuration.defaultWebpagePreferences.preferredHTTPSNavigationPolicy =
        settings.https_only ? WKWebpagePreferencesUpgradeToHTTPSPolicyErrorOnFailure
                            : WKWebpagePreferencesUpgradeToHTTPSPolicyKeepAsRequested;
  }

  WKUserContentController* controller = self.webKitView.configuration.userContentController;
  [controller removeAllContentRuleLists];

  if (settings.block_trackers && !trackerDomains.empty()) {
    NSString* identifier = @"prifacie-trackers";
    std::ostringstream rulesJson;
    rulesJson << "[";
    for (std::size_t i = 0; i < trackerDomains.size(); ++i) {
      const std::string regex =
          "^https?://([^/]+\\.)?" + RegexEscape(trackerDomains[i]) + "(/|$)";
      rulesJson << "{\"trigger\":{\"url-filter\":\"" << JsonEscape(regex)
                << "\",\"load-type\":[\"third-party\"]},\"action\":{\"type\":\"block\"}}";
      if (i + 1 < trackerDomains.size()) rulesJson << ",";
    }
    rulesJson << "]";
    [self compileRuleListWithIdentifier:identifier
                              rulesJson:ToNSString(rulesJson.str())
                             controller:controller];
  }

  if (settings.block_third_party_cookies) {
    NSString* identifier = @"prifacie-thirdparty-cookie";
    NSString* rulesJson =
        @"[{\"trigger\":{\"url-filter\":\".*\",\"load-type\":[\"third-party\"]},\"action\":{\"type\":\"block-cookies\"}}]";
    [self compileRuleListWithIdentifier:identifier rulesJson:rulesJson controller:controller];
  }
}

- (void)clearBrowsingDataWithCompletion:(dispatch_block_t)completion {
  if (!self.webKitView) {
    if (completion) completion();
    return;
  }

  WKWebsiteDataStore* store = self.webKitView.configuration.websiteDataStore;
  NSSet<NSString*>* types = [WKWebsiteDataStore allWebsiteDataTypes];
  [store removeDataOfTypes:types
             modifiedSince:[NSDate dateWithTimeIntervalSince1970:0]
         completionHandler:^{
           if (completion) completion();
         }];
}

- (void)dumpWebsiteDataSummary:(void (^)(NSArray<NSString*>* lines))completion {
  if (!completion) return;

  if (!self.webKitView) {
    completion(@[
      [NSString stringWithFormat:@"[WEBSITE DATA STORE] %@",
                                 self.webDataEphemeral ? @"Ephemeral (in-memory)" : @"Engine-managed"],
      @"[WEBSITE DATA] Summary unavailable for Gecko stub backend in this build.",
    ]);
    return;
  }

  WKWebsiteDataStore* store = self.webKitView.configuration.websiteDataStore;
  NSSet<NSString*>* types = [WKWebsiteDataStore allWebsiteDataTypes];
  [store fetchDataRecordsOfTypes:types
               completionHandler:^(NSArray<WKWebsiteDataRecord*>* records) {
                 NSMutableArray<NSString*>* lines = [[NSMutableArray alloc] init];
                 [lines addObject:[NSString stringWithFormat:@"[WEBSITE DATA STORE] %@",
                                                             self.webDataEphemeral ? @"Ephemeral (in-memory)"
                                                                                   : @"Persistent"]];
                 [lines addObject:[NSString stringWithFormat:@"[WEBSITE DATA] %lu record(s)",
                                                             (unsigned long)records.count]];
                 for (NSUInteger i = 0; i < records.count && i < 30; ++i) {
                   WKWebsiteDataRecord* record = records[i];
                   [lines addObject:[NSString stringWithFormat:@"- %@ (%lu data type(s))",
                                                               record.displayName,
                                                               (unsigned long)record.dataTypes.count]];
                 }
                 completion(lines);
               }];
}

- (void)shutdown {
  if (!self.webKitView) return;
  [self.webKitView.configuration.userContentController
      removeScriptMessageHandlerForName:@(kDevLogMessageHandlerName)];
}

@end
