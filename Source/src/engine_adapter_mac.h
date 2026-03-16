#pragma once

#import <Cocoa/Cocoa.h>
#import <WebKit/WebKit.h>

#include <string>
#include <vector>

#include "profile_store.h"

typedef NS_ENUM(NSUInteger, PriFacieEngineBackend) {
  PriFacieEngineBackendWebKit = 0,
  PriFacieEngineBackendGecko = 1,
};

PriFacieEngineBackend ResolveEngineBackendFromEnvironment();
NSString* PriFacieEngineBackendDisplayName(PriFacieEngineBackend backend);

@interface PriFacieEngineAdapter : NSObject
@property(nonatomic, readonly) PriFacieEngineBackend backend;
@property(nonatomic, readonly) BOOL webDataEphemeral;

- (instancetype)initWithBackend:(PriFacieEngineBackend)backend NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;

- (NSString*)engineDisplayName;
- (NSView*)contentView;
- (WKWebView*)webView;

- (void)initializeEngineWithProfileStore:(ProfileStore*)profileStore
                             profileName:(const std::string&)profileName
                                settings:(const BrowserSettings&)settings
                           messageTarget:(id<WKScriptMessageHandler>)messageTarget
                      navigationDelegate:(id<WKNavigationDelegate>)navigationDelegate
                              uiDelegate:(id<WKUIDelegate>)uiDelegate;

- (void)applyPrivacySettings:(const BrowserSettings&)settings
              trackerDomains:(const std::vector<std::string>&)trackerDomains;

- (void)clearBrowsingDataWithCompletion:(dispatch_block_t)completion;
- (void)dumpWebsiteDataSummary:(void (^)(NSArray<NSString*>* lines))completion;
- (void)shutdown;
@end
