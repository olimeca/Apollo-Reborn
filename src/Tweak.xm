#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <sys/utsname.h>
#import <Security/Security.h>
#import <StoreKit/StoreKit.h>
#import <AuthenticationServices/AuthenticationServices.h>

#import "fishhook.h"
#import "ApolloCommon.h"
#import "ApolloRedditMediaUpload.h"
#import "ApolloDeletedCommentsData.h"
#import "ApolloImageUploadHost.h"
#import "ApolloNotificationBackend.h"
#import "ApolloState.h"
#import "Tweak.h"
#import "CustomAPIViewController.h"
#import "UserDefaultConstants.h"
#import "Defaults.h"
#import "ApolloMarkdownToolbarGif.h"
#import "ApolloWebAuthViewController.h"

// MARK: - RedGIFs Playback Fix & JSON Traversal

%hook NSJSONSerialization

+ (id)JSONObjectWithData:(NSData *)data options:(NSJSONReadingOptions)opt error:(NSError **)error {
    id json = %orig(data, opt, error);
    
    if ([json isKindOfClass:[NSDictionary class]]) {
        NSMutableDictionary *mutableJson = [json mutableCopy];
        [self modifyRedditPayload:mutableJson];
        return [mutableJson copy];
    } else if ([json isKindOfClass:[NSArray class]]) {
        NSMutableArray *mutableArray = [json mutableCopy];
        for (NSUInteger i = 0; i < mutableArray.count; i++) {
            if ([mutableArray[i] isKindOfClass:[NSDictionary class]]) {
                NSMutableDictionary *mutableDict = [mutableArray[i] mutableCopy];
                [self modifyRedditPayload:mutableDict];
                mutableArray[i] = [mutableDict copy];
            }
        }
        return [mutableArray copy];
    }
    
    return json;
}

%new
+ (void)modifyRedditPayload:(NSMutableDictionary *)dict {
    for (NSString *key in [dict allKeys]) {
        id value = dict[key];
        if ([value isKindOfClass:[NSMutableDictionary class]]) {
            [self modifyRedditPayload:value];
        } else if ([value isKindOfClass:[NSDictionary class]]) {
            NSMutableDictionary *mutableChild = [value mutableCopy];
            [self modifyRedditPayload:mutableChild];
            dict[key] = [mutableChild copy];
        } else if ([value isKindOfClass:[NSArray class]]) {
            NSMutableArray *mutableArray = [value mutableCopy];
            for (NSUInteger i = 0; i < mutableArray.count; i++) {
                if ([mutableArray[i] isKindOfClass:[NSDictionary class]]) {
                    NSMutableDictionary *mutableDict = [mutableArray[i] mutableCopy];
                    [self modifyRedditPayload:mutableDict];
                    mutableArray[i] = [mutableDict copy];
                }
            }
            dict[key] = [mutableArray copy];
        }
    }

    // Strip out the transcoded silent preview block to force Apollo to use url_overridden_by_dest
    if ([dict objectForKey:@"reddit_video_preview"]) {
        [dict removeObjectForKey:@"reddit_video_preview"];
    }
    
    // Explicitly fix audio flags for RedGIFs links if fallback tracking fails
    if ([dict objectForKey:@"is_gif"] && [[dict objectForKey:@"is_gif"] boolValue] == YES) {
        NSString *urlDest = dict[@"url_overridden_by_dest"];
        if (urlDest && ([urlDest containsString:@"redgifs.com"] || [urlDest containsString:@"v3.redgifs.com"])) {
            dict[@"is_gif"] = @NO;
            dict[@"has_audio"] = @YES;
        }
    }
}

%end

// MARK: - Sideload Fixes

static NSDictionary *stripGroupAccessAttr(CFDictionaryRef attributes) {
    NSMutableDictionary *newAttributes = [[NSMutableDictionary alloc] initWithDictionary:(__bridge id)attributes];
    [newAttributes removeObjectForKey:(__bridge id)kSecAttrAccessGroup];
    return newAttributes;
}

// Ultra/Pro status: Valet (SharedGroupValet) stores these in the keychain.
// Key names are obfuscated. Valet's internal service name includes the full initializer description.
static NSString *const kValetServiceSubstring = @"com.christianselig.Apollo";

// Map of obfuscated Valet account keys -> override values (from RE of isApolloUltraEnabled/isApolloProEnabled)
static NSString *ValetOverrideValue(NSString *account) {
    static NSDictionary *overrideMap;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        overrideMap = @{
            @"meganotifs":              @"affirmative", // Ultra
            @"seconds_since2":          @"1473982",     // Pro
            @"rep_seconds_since2":      @"1473982",     // Pro (alternate?)
            @"rep_seconds_after2":      @"1482118",     // SPCA Animals icon pack
        };
    });
    return overrideMap[account];
}

static BOOL IsValetQuery(NSDictionary *query) {
    NSString *service = query[(__bridge id)kSecAttrService];
    return service && [service containsString:kValetServiceSubstring];
}

static BOOL IsUltraProOverrideKey(NSDictionary *query) {
    NSString *account = query[(__bridge id)kSecAttrAccount];
    if (!account) return NO;
    if (!IsValetQuery(query)) return NO;
    return ValetOverrideValue(account) != nil;
}

static NSData *OverrideDataForAccount(NSString *account) {
    NSString *value = ValetOverrideValue(account);
    return [value dataUsingEncoding:NSUTF8StringEncoding];
}

static void *SecItemAdd_orig;
static OSStatus SecItemAdd_replacement(CFDictionaryRef query, CFTypeRef *result) {
    NSDictionary *strippedQuery = stripGroupAccessAttr(query);
    return ((OSStatus (*)(CFDictionaryRef, CFTypeRef *))SecItemAdd_orig)((__bridge CFDictionaryRef)strippedQuery, result);
}

static void *SecItemCopyMatching_orig;
static OSStatus SecItemCopyMatching_replacement(CFDictionaryRef query, CFTypeRef *result) {
    NSDictionary *strippedQuery = stripGroupAccessAttr(query);

    // Intercept Ultra/Pro Valet reads and return override values
    if (IsUltraProOverrideKey(strippedQuery)) {
        NSString *account = strippedQuery[(__bridge id)kSecAttrAccount];
        if (result) {
            NSData *overrideData = OverrideDataForAccount(account);
            if (strippedQuery[(__bridge id)kSecReturnAttributes]) {
                *result = (__bridge_retained CFTypeRef)@{
                    (__bridge id)kSecAttrAccount: account,
                    (__bridge id)kSecValueData: overrideData,
                };
            } else {
                *result = (__bridge_retained CFTypeRef)overrideData;
            }
        }
        return errSecSuccess;
    }

    return ((OSStatus (*)(CFDictionaryRef, CFTypeRef *))SecItemCopyMatching_orig)((__bridge CFDictionaryRef)strippedQuery, result);
}

static void *SecItemUpdate_orig;
static OSStatus SecItemUpdate_replacement(CFDictionaryRef query, CFDictionaryRef attributesToUpdate) {
    NSDictionary *strippedQuery = stripGroupAccessAttr(query);

    // Block attempts to disable Ultra/Pro
    if (IsUltraProOverrideKey(strippedQuery)) {
        return errSecSuccess;
    }

    return ((OSStatus (*)(CFDictionaryRef, CFDictionaryRef))SecItemUpdate_orig)((__bridge CFDictionaryRef)strippedQuery, attributesToUpdate);
}

// --- Device detection (for Pixel Pals and Dynamic Island behaviour) ---
// Apollo's device model mapper (sub_1007a3cdc) only recognizes models up to iPhone 14 Pro Max.
// Newer models return "unknown" (0x3f) and get no Pixel Pals.
// Remap newer machine identifiers to "iPhone15,2" (iPhone 14 Pro) so Apollo
// treats them as Dynamic Island devices and enables full Pixel Pals + FauxCutOutView.
static void *uname_orig;
static int uname_replacement(struct utsname *buf) {
    int ret = ((int (*)(struct utsname *))uname_orig)(buf);
    if (ret != 0) return ret;

    // iPhone15,4+ are all unrecognized by Apollo's mapper.
    // Map Dynamic Island models to iPhone15,2 (iPhone 14 Pro) and notch models to iPhone14,7 (iPhone 14)
    static NSDictionary *modelRemap;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        NSString *di    = @"iPhone15,2";  // iPhone 14 Pro (Dynamic Island)
        NSString *notch = @"iPhone14,7";  // iPhone 14 (notch)

        modelRemap = @{
            @"iPhone15,4": di,    // iPhone 15
            @"iPhone15,5": di,    // iPhone 15 Plus
            @"iPhone16,1": di,    // iPhone 15 Pro
            @"iPhone16,2": di,    // iPhone 15 Pro Max
            @"iPhone17,1": di,    // iPhone 16 Pro
            @"iPhone17,2": di,    // iPhone 16 Pro Max
            @"iPhone17,3": di,    // iPhone 16
            @"iPhone17,4": di,    // iPhone 16 Plus
            @"iPhone17,5": notch, // iPhone 16e
            @"iPhone18,1": di,    // iPhone 17 Pro
            @"iPhone18,2": di,    // iPhone 17 Pro Max
            @"iPhone18,3": di,    // iPhone 17
            @"iPhone18,4": di,    // iPhone Air
            @"iPhone18,5": notch, // iPhone 17e
        };
    });

    NSString *machine = @(buf->machine);
    NSString *remap = modelRemap[machine];
    if (remap) {
        strlcpy(buf->machine, remap.UTF8String, sizeof(buf->machine));
    }
    return ret;
}

// MARK: - API / Network

static NSString *const announcementUrl = @"apollogur.download/api/apollonouncement";

static NSArray *const blockedUrls = @[
    @"apollopushserver.xyz",
    @"apollonotifications.com",
    @"beta.apollonotifications.com",
    @"apolloreq.com",
    @"notify.bugsnag.com",
    @"sessions.bugsnag.com",
    @"api.mixpanel.com",
    @"api.statsig.com",
    @"statsigapi.net",
    @"telemetrydeck.com",
    @"apollogur.download/api/easter_sale",
    @"apollogur.download/api/html_codes",
    @"apollogur.download/api/refund_screen_config",
    @"apollogur.download/api/goodbye_wallpaper"
];

// Cache storing subreddit list source URLs -> response body
static NSCache<NSString *, NSString *> *subredditListCache;
// Replace Reddit API client ID
%hook RDKOAuthCredential

- (NSString *)clientIdentifier {
    return sRedditClientId;
}

- (NSURL *)redirectURI {
    NSString *customURI = [sRedirectURI length] > 0 ? sRedirectURI : defaultRedirectURI;
    return [NSURL URLWithString:customURI];
}

%end

static const char kARScheme     = '\0';
static const char kARAuthURL    = '\0';
static const char kARCompletion = '\0';

// Replace ASWebAuthenticationSession with a WKWebView-based flow for all
// Reddit OAuth sign-ins. WKNavigationDelegate fires decidePolicyForNavigationAction
// for every URL before iOS URL routing, so the callback can be intercepted
// regardless of whether the redirect URI scheme is registered in CFBundleURLTypes.
%hook ASWebAuthenticationSession

- (instancetype)initWithURL:(NSURL *)URL
        callbackURLScheme:(NSString *)callbackURLScheme
        completionHandler:(void (^)(NSURL *, NSError *))completionHandler {
    id result = %orig;
    id target = result ?: self;
    objc_setAssociatedObject(target, &kARScheme,     callbackURLScheme, OBJC_ASSOCIATION_COPY);
    objc_setAssociatedObject(target, &kARAuthURL,    URL,               OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(target, &kARCompletion, completionHandler, OBJC_ASSOCIATION_COPY);
    return result;
}

- (BOOL)start {
    NSString *callbackScheme = objc_getAssociatedObject(self, &kARScheme);
    NSURL *authURL            = objc_getAssociatedObject(self, &kARAuthURL);
    void (^completion)(NSURL *, NSError *) = objc_getAssociatedObject(self, &kARCompletion);

    if (!authURL || !completion) {
        ApolloLog(@"[WebAuth] missing authURL or completion — falling back to %%orig");
        return %orig;
    }

    // Prefer the scheme from redirect_uri in the auth URL (set by our
    // RDKOAuthCredential hook); fall back to callbackURLScheme if not found.
    NSString *interceptScheme = callbackScheme;
    for (NSURLQueryItem *item in [NSURLComponents componentsWithURL:authURL resolvingAgainstBaseURL:NO].queryItems) {
        if ([item.name isEqualToString:@"redirect_uri"]) {
            NSString *s = [NSURL URLWithString:item.value].scheme;
            if (s.length) interceptScheme = s;
            break;
        }
    }

    ApolloLog(@"[WebAuth] using WKWebView, intercepting scheme=%@", interceptScheme);

    // Use Apollo's own presentationContextProvider — it's set before start is called
    // and returns the correct window. start is already on the main queue.
    id<ASWebAuthenticationPresentationContextProviding> provider = [self presentationContextProvider];
    UIWindow *window = [provider presentationAnchorForWebAuthenticationSession:self];

    if (!window) {
        for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
            if (scene.activationState == UISceneActivationStateForegroundActive
                    && [scene isKindOfClass:[UIWindowScene class]]) {
                window = ((UIWindowScene *)scene).keyWindow ?: ((UIWindowScene *)scene).windows.firstObject;
                break;
            }
        }
    }

    ApolloLog(@"[WebAuth] presenting from window=%@", window);

    ApolloWebAuthViewController *authVC = [[ApolloWebAuthViewController alloc]
        initWithURL:authURL callbackScheme:interceptScheme completionHandler:completion];
    UINavigationController *nav = [[UINavigationController alloc] initWithRootViewController:authVC];
    nav.modalPresentationStyle = UIModalPresentationFormSheet;

    UIViewController *top = window.rootViewController;
    while (top.presentedViewController) top = top.presentedViewController;
    [top presentViewController:nav animated:YES completion:nil];

    return YES;
}

%end

%hook RDKClient

- (NSString *)userAgent {
    NSString *customUA = [sUserAgent length] > 0 ? sUserAgent : defaultUserAgent;
    return customUA;
}

// Defensive guard: bail out if the response isn't a dictionary. Apollo otherwise
// crashes with "unrecognized selector" when it does `response[@"kind"]` on a string.
- (NSArray *)objectsFromListingResponse:(id)response {
    if (![response isKindOfClass:[NSDictionary class]]) {
        ApolloLog(@"[ListingResponse] Non-dict response of class %@; returning nil to avoid crash", NSStringFromClass([response class]));
        return nil;
    }
    return %orig;
}

%end

// Same defensive guard for the sibling pagination call. Apollo's listing block calls
// both +[RDKPagination paginationFromListingResponse:] and the above on the same
// response; pagination crashes on `[response valueForKeyPath:@"data.before"]`.
%hook RDKPagination

+ (instancetype)paginationFromListingResponse:(id)response {
    if (![response isKindOfClass:[NSDictionary class]]) {
        ApolloLog(@"[ListingResponse] Non-dict response of class %@; skipping pagination", NSStringFromClass([response class]));
        return nil;
    }
    return %orig;
}

%end

// Randomise the trending subreddits list
%hook NSBundle
-(NSURL *)URLForResource:(NSString *)name withExtension:(NSString *)ext {
    NSURL *url = %orig;
    if ([name isEqualToString:@"trending-subreddits"] && [ext isEqualToString:@"plist"]) {
        NSURL *subredditListURL = [NSURL URLWithString:sTrendingSubredditsSource];
        NSDateFormatter *formatter = [[NSDateFormatter alloc] init];
        // ex: 2023-9-28 (28th September 2023)
        [formatter setDateFormat:@"yyyy-M-d"];

        /*
            - Parse plist
            - Select random list of subreddits from the dict
            - Add today's date to the dict, with the list as the value
            - Return plist as a new file
        */
        NSMutableDictionary *fallbackDict = [[NSDictionary dictionaryWithContentsOfURL:url] mutableCopy];
        // Select random array from dict
        NSArray *fallbackKeys = [fallbackDict allKeys];
        NSString *randomFallbackKey = fallbackKeys[arc4random_uniform((uint32_t)[fallbackKeys count])];
        NSArray *fallbackArray = fallbackDict[randomFallbackKey];
        if ([[NSUserDefaults standardUserDefaults] boolForKey:UDKeyShowRandNsfw]) {
            fallbackArray = [fallbackArray arrayByAddingObject:@"RandNSFW"];
        }
        [fallbackDict setObject:fallbackArray forKey:[formatter stringFromDate:[NSDate date]]];

        NSURL * (^writeDict)(NSMutableDictionary *d) = ^(NSMutableDictionary *d){
            // write new file
            NSString *tempPath = [NSTemporaryDirectory() stringByAppendingPathComponent:@"trending-custom.plist"];
            [[NSFileManager defaultManager] removeItemAtPath:tempPath error:nil]; // remove in case it exists
            [d writeToFile:tempPath atomically:YES];
            return [NSURL fileURLWithPath:tempPath];
        };

        __block NSError *error = nil;
        __block NSString *subredditListContent = nil;

        // Try fetching the subreddit list from the source URL, with timeout of 5 seconds
        // FIXME: Blocks the UI during the splash screen
        dispatch_semaphore_t semaphore = dispatch_semaphore_create(0);
        NSURLRequest *request = [NSURLRequest requestWithURL:subredditListURL cachePolicy:NSURLRequestUseProtocolCachePolicy timeoutInterval:5.0];
        NSURLSession *session = [NSURLSession sharedSession];
        NSURLSessionDataTask *dataTask = [session dataTaskWithRequest:request completionHandler:^(NSData *data, NSURLResponse *response, NSError *e) {
            if (e) {
                error = e;
            } else {
                NSHTTPURLResponse *httpResponse = (NSHTTPURLResponse *)response;
                if (httpResponse.statusCode == 200) {
                    subredditListContent = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
                }
            }
            dispatch_semaphore_signal(semaphore);
        }];
        [dataTask resume];
        dispatch_semaphore_wait(semaphore, DISPATCH_TIME_FOREVER);

        // Use fallback dict if there was an error
        if (error || ![subredditListContent length]) {
            return writeDict(fallbackDict);
        }

        // Parse into array
        NSMutableArray<NSString *> *subreddits = [[subredditListContent componentsSeparatedByCharactersInSet:[NSCharacterSet newlineCharacterSet]] mutableCopy];
        [subreddits filterUsingPredicate:[NSPredicate predicateWithFormat:@"length > 0"]];
        if (subreddits.count == 0) {
            return writeDict(fallbackDict);
        }

        NSMutableDictionary *dict = [NSMutableDictionary dictionary];
        // Randomize and limit subreddits
        bool limitSubreddits = [sTrendingSubredditsLimit length] > 0;
        if (limitSubreddits && [sTrendingSubredditsLimit integerValue] < subreddits.count) {
            NSUInteger count = [sTrendingSubredditsLimit integerValue];
            NSMutableArray<NSString *> *randomSubreddits = [NSMutableArray arrayWithCapacity:count];
            for (NSUInteger i = 0; i < count; i++) {
                NSUInteger randomIndex = arc4random_uniform((uint32_t)subreddits.count);
                [randomSubreddits addObject:subreddits[randomIndex]];
                // Remove to prevent duplicates
                [subreddits removeObjectAtIndex:randomIndex];
            }
            subreddits = randomSubreddits;
        }

        if ([[NSUserDefaults standardUserDefaults] boolForKey:UDKeyShowRandNsfw]) {
            [subreddits addObject:@"RandNSFW"];
        }
        [dict setObject:subreddits forKey:[formatter stringFromDate:[NSDate date]]];
        return writeDict(dict);
    }
    return url;
}


// Sideloaded builds have no App Store receipt file, so Apollo's receipt check
// fails immediately with "Unable to retrieve receipt information..." before it
// even attempts SKReceiptRefreshRequest. Returning a path to a real (dummy) file
// satisfies the file-exists check and lets Apollo proceed to backend registration.
- (NSURL *)appStoreReceiptURL {
    static NSString *dummyPath;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        dummyPath = [NSTemporaryDirectory() stringByAppendingPathComponent:@"apollo_dummy_receipt"];
    });
    if (![[NSFileManager defaultManager] fileExistsAtPath:dummyPath]) {
        // Minimal ASN.1 SEQUENCE shell — non-empty so basic format checks pass
        uint8_t bytes[] = {0x30, 0x01, 0x00};
        [[NSData dataWithBytes:bytes length:sizeof(bytes)] writeToFile:dummyPath atomically:YES];
    }
    ApolloLog(@"[StoreKit] Spoofing appStoreReceiptURL -> %@", dummyPath);
    return [NSURL fileURLWithPath:dummyPath];
}
%end

// Does not work on iOS 26+
%hook NSURL

// Rewrite x.com links as twitter.com
- (NSString *)host {
    NSString *originalHost = %orig;
    if (originalHost && [originalHost isEqualToString:@"x.com"]) {
        return @"twitter.com";
    }
    return originalHost;
}
%end

// Implementation derived from https://github.com/ichitaso/ApolloPatcher/blob/v0.0.5/Tweak.x
// Credits to @ichitaso for the original implementation

@interface NSURLSession (Private)
- (BOOL)isJSONResponse:(NSURLResponse *)response;
@end

// Strip RapidAPI-specific headers when redirecting to direct Imgur API
static void StripRapidAPIHeaders(NSMutableURLRequest *request) {
    [request setValue:nil forHTTPHeaderField:@"X-RapidAPI-Key"];
    [request setValue:nil forHTTPHeaderField:@"X-RapidAPI-Host"];
}

static NSURLRequest *ApolloLocalFastFailRequest(NSString *path) {
    NSString *suffix = path.length > 0 ? path : @"apollo-local";
    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:[@"http://127.0.0.1:1/" stringByAppendingString:suffix]]];
    request.HTTPMethod = @"POST";
    request.timeoutInterval = 1.0;
    return request;
}

%hook NSURLSession

- (NSURLSessionDataTask *)dataTaskWithRequest:(NSURLRequest *)request {
    ApolloRedditCaptureBearerTokenFromRequest(request, @"NSURLSession dataTaskWithRequest:");
    ApolloDeletedCommentsHandleRequestObservation(request, @"dataTaskWithRequest:");
    ApolloDeletedCommentsInstallDelegateTransformerIfNeeded((NSURLSession *)self, request);

    NSURLRequest *redditMediaSubmitRequest = ApolloRedditMaybeRewriteSubmitRequest(request);
    if (redditMediaSubmitRequest) {
        ApolloRedditInstallResponseTransformerForDelegate(self.delegate);
        NSURLSessionDataTask *task = %orig(redditMediaSubmitRequest);
        ApolloRedditAssociateSubmitRequestWithTask(task, redditMediaSubmitRequest);
        return task;
    }

    NSURLRequest *redditMediaCommentRequest = ApolloRedditMaybeRewriteCommentRequest(request);
    if (redditMediaCommentRequest) {
        ApolloRedditInstallResponseTransformerForDelegate(self.delegate);
        return %orig(redditMediaCommentRequest);
    }

    NSURL *url = [request URL];
    NSURL *subredditListURL;

    // Reroute URL-shaped search queries to /api/info?url=<URL>. Reddit's /search.json
    // 302-redirects URL-shaped queries to /submit.json (and on to /login), producing
    // a non-Listing response that crashes Apollo's parser. /api/info returns a proper
    // Listing for both Reddit and external URLs.
    BOOL isPostSearch = [url.host isEqualToString:@"oauth.reddit.com"] &&
        ([url.path isEqualToString:@"/search.json"] ||
         ([url.path hasPrefix:@"/r/"] && [url.path hasSuffix:@"/search.json"]));
    if (isPostSearch) {
        NSURLComponents *components = [NSURLComponents componentsWithURL:url resolvingAgainstBaseURL:NO];
        NSString *q = nil;
        for (NSURLQueryItem *item in components.queryItems) {
            if ([item.name isEqualToString:@"q"]) {
                q = item.value;
                break;
            }
        }
        if (q.length > 0 && ([q hasPrefix:@"http://"] || [q hasPrefix:@"https://"])) {
            NSURLComponents *rewritten = [[NSURLComponents alloc] init];
            rewritten.scheme = @"https";
            rewritten.host = @"oauth.reddit.com";
            rewritten.path = @"/api/info.json";
            rewritten.queryItems = @[
                [NSURLQueryItem queryItemWithName:@"url" value:q],
                [NSURLQueryItem queryItemWithName:@"raw_json" value:@"1"],
            ];
            NSMutableURLRequest *modifiedRequest = [request mutableCopy];
            [modifiedRequest setURL:rewritten.URL];
            ApolloLog(@"[URLSearch] Rerouting URL search to /api/info.json. Original: %@ Rewritten: %@", url.absoluteString, rewritten.URL.absoluteString);
            return %orig(modifiedRequest);
        }
    }

    // Determine whether request is for random subreddit
    if ([url.host isEqualToString:@"oauth.reddit.com"] && [url.path hasPrefix:@"/r/random/"]) {
        if (![sRandomSubredditsSource length]) {
            return %orig;
        }
        subredditListURL = [NSURL URLWithString:sRandomSubredditsSource];
    } else if ([url.host isEqualToString:@"oauth.reddit.com"] && [url.path hasPrefix:@"/r/randnsfw/"]) {
        if (![sRandNsfwSubredditsSource length]) {
            return %orig;
        }
        subredditListURL = [NSURL URLWithString:sRandNsfwSubredditsSource];
    } else {
        return %orig;
    }

    NSError *error = nil;
    // Check cache
    NSString *subredditListContent = [subredditListCache objectForKey:subredditListURL.absoluteString];
    bool updateCache = false;

    if (!subredditListContent) {
        // Not in cache, so fetch subreddit list from source URL
        // FIXME: The current implementation blocks the UI, but the prefetching in initializeRandomSources() should help
        subredditListContent = [NSString stringWithContentsOfURL:subredditListURL encoding:NSUTF8StringEncoding error:&error];
        if (error) {
            return %orig;
        }
        updateCache = true;
    }

    // Parse the content into a list of strings
    NSArray<NSString *> *subreddits = [subredditListContent componentsSeparatedByCharactersInSet:[NSCharacterSet newlineCharacterSet]];
    subreddits = [subreddits filteredArrayUsingPredicate:[NSPredicate predicateWithFormat:@"length > 0"]];
    if (subreddits.count == 0) {
        return %orig;
    }

    if (updateCache) {
        [subredditListCache setObject:subredditListContent forKey:subredditListURL.absoluteString];
    }

    // Pick a random subreddit, then modify the request URL to use that subreddit, simulating a 302 redirect in Reddit's original API behaviour
    NSString *randomSubreddit = subreddits[arc4random_uniform((uint32_t)subreddits.count)];
    NSString *urlString = [url absoluteString];
    NSString *newUrlString = [urlString stringByReplacingOccurrencesOfString:@"/random/" withString:[NSString stringWithFormat:@"/%@/", randomSubreddit]];
    newUrlString = [newUrlString stringByReplacingOccurrencesOfString:@"/randnsfw/" withString:[NSString stringWithFormat:@"/%@/", randomSubreddit]];

    NSMutableURLRequest *modifiedRequest = [request mutableCopy];
    [modifiedRequest setURL:[NSURL URLWithString:newUrlString]];
    return %orig(modifiedRequest);
}

// Imgur Delete and album creation
- (NSURLSessionDataTask*)dataTaskWithRequest:(NSURLRequest*)request completionHandler:(void (^)(NSData*, NSURLResponse*, NSError*))completionHandler {
    ApolloRedditCaptureBearerTokenFromRequest(request, @"NSURLSession dataTaskWithRequest:completionHandler:");
    ApolloDeletedCommentsHandleRequestObservation(request, @"dataTaskWithRequest:completionHandler:");

    NSURLRequest *redditMediaSubmitRequest = ApolloRedditMaybeRewriteSubmitRequest(request);
    if (redditMediaSubmitRequest) {
        void (^wrappedSubmitCompletionHandler)(NSData *, NSURLResponse *, NSError *) = ^(NSData *data, NSURLResponse *response, NSError *error) {
            ApolloRedditTransformSubmitResponseAsync(data, redditMediaSubmitRequest, ^(NSData *transformed) {
                completionHandler(transformed.length > 0 ? transformed : data, response, error);
            });
        };
        return %orig(redditMediaSubmitRequest, wrappedSubmitCompletionHandler);
    }

    NSURLRequest *redditMediaCommentRequest = ApolloRedditMaybeRewriteCommentRequest(request);
    if (redditMediaCommentRequest) {
        void (^wrappedCompletionHandler)(NSData *, NSURLResponse *, NSError *) = ^(NSData *data, NSURLResponse *response, NSError *error) {
            ApolloRedditTransformCommentResponseAsync(data, ^(NSData *transformed) {
                completionHandler(transformed.length > 0 ? transformed : data, response, error);
            });
        };
        return %orig(redditMediaCommentRequest, wrappedCompletionHandler);
    }

    NSURL *url = [request URL];
    NSString *host = [url host];
    NSString *path = [url path];

    NSData *redditAlbumResponseData = sImageUploadProvider == ImageUploadProviderReddit ? ApolloRedditSyntheticImgurAlbumResponseDataForRequest(request) : nil;
    if (sImageUploadProvider == ImageUploadProviderReddit && redditAlbumResponseData.length > 0) {
        NSHTTPURLResponse *fakeHTTPResponse = [[NSHTTPURLResponse alloc] initWithURL:url
                                                                          statusCode:200
                                                                         HTTPVersion:@"HTTP/1.1"
                                                                        headerFields:@{@"Content-Type": @"application/json"}];
        void (^wrappedHandler)(NSData *, NSURLResponse *, NSError *) = ^(__unused NSData *data, __unused NSURLResponse *response, __unused NSError *error) {
            completionHandler(redditAlbumResponseData, fakeHTTPResponse, nil);
        };
        return %orig(ApolloLocalFastFailRequest(@"apollo-reddit-gallery-album"), wrappedHandler);
    }

    if ([host isEqualToString:@"imgur-apiv3.p.rapidapi.com"] && [path hasPrefix:@"/3/album"]) {
        // Album creation needs body format conversion (form-urlencoded → JSON)
        // URL redirect and auth are handled by _onqueue_resume
        NSMutableURLRequest *modifiedRequest = [request mutableCopy];
        [modifiedRequest setURL:[NSURL URLWithString:[@"https://api.imgur.com" stringByAppendingString:path]]];
        StripRapidAPIHeaders(modifiedRequest);
        NSString *bodyString = [[NSString alloc] initWithData:modifiedRequest.HTTPBody encoding:NSUTF8StringEncoding];
        NSArray *components = [bodyString componentsSeparatedByString:@"="];
        if (components.count == 2 && [components[0] isEqualToString:@"deletehashes"]) {
            NSString *deleteHashes = components[1];
            NSArray *hashes = [deleteHashes componentsSeparatedByString:@","];
            NSDictionary *jsonBody = @{@"deletehashes": hashes};
            NSData *jsonData = [NSJSONSerialization dataWithJSONObject:jsonBody options:0 error:nil];
            [modifiedRequest setHTTPBody:jsonData];
            [modifiedRequest setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];
        }
        return %orig(modifiedRequest, completionHandler);
    } else if ([host isEqualToString:@"api.redgifs.com"] && [path isEqualToString:@"/v2/oauth/client"]) {
        // Redirect to the new temporary token endpoint
        NSMutableURLRequest *modifiedRequest = [request mutableCopy];
        NSURL *newURL = [NSURL URLWithString:@"https://api.redgifs.com/v2/auth/temporary"];
        [modifiedRequest setURL:newURL];
        [modifiedRequest setHTTPMethod:@"GET"];
        [modifiedRequest setHTTPBody:nil];
        [modifiedRequest setValue:nil forHTTPHeaderField:@"Content-Type"];
        [modifiedRequest setValue:nil forHTTPHeaderField:@"Content-Length"];

        void (^newCompletionHandler)(NSData *data, NSURLResponse *response, NSError *error) = ^(NSData *data, NSURLResponse *response, NSError *error) {
            if (!error && data) {
                NSError *jsonError = nil;
                NSDictionary *json = [NSJSONSerialization JSONObjectWithData:data options:0 error:&jsonError];
                if (!jsonError && json[@"token"]) {
                    // Transform response to match Apollo's format from '/v2/oauth/client'
                    NSDictionary *oauthResponse = @{
                        @"access_token": json[@"token"],
                        @"token_type": @"Bearer",
                        @"expires_in": @(82800), // 23 hours
                        @"scope": @"read"
                    };
                    NSData *transformedData = [NSJSONSerialization dataWithJSONObject:oauthResponse options:0 error:nil];
                    completionHandler(transformedData, response, error);
                    return;
                }
            }
            completionHandler(data, response, error);
        };
        return %orig(modifiedRequest, newCompletionHandler);
    }
    return %orig(request, ApolloDeletedCommentsMaybeWrapCompletion(request, completionHandler));
}

// "Unproxy" Imgur requests
- (NSURLSessionDataTask *)dataTaskWithURL:(NSURL *)url completionHandler:(void (^)(NSData *, NSURLResponse *, NSError *))completionHandler {
    NSURLRequest *observeRequest = url ? [NSURLRequest requestWithURL:url] : nil;
    ApolloDeletedCommentsHandleRequestObservation(observeRequest, @"dataTaskWithURL:completionHandler:");

    if ([url.host isEqualToString:@"apollogur.download"]) {
        NSString *imageID = [url.lastPathComponent stringByDeletingPathExtension];

        if (sProxyImgurDDG && [url.path hasPrefix:@"/api/image"]) {
            // Fabricate an API response with a DDG-proxied link, skipping api.imgur.com
            // entirely (also regionally blocked). .jpg is a neutral default; Imgur serves
            // the correct format regardless and DDG handles both static and animated content.
            NSString *imgurJPG = [NSString stringWithFormat:@"https://i.imgur.com/%@.jpg", imageID];
            NSString *ddgProxied = [@"https://external-content.duckduckgo.com/iu/?u=" stringByAppendingString:
                [imgurJPG stringByAddingPercentEncodingWithAllowedCharacters:[NSCharacterSet URLQueryAllowedCharacterSet]]];

            // Match the real Imgur API shape so Unbox's required-key decoding succeeds.
            NSDictionary *syntheticResponse = @{
                @"status": @200,
                @"success": @YES,
                @"data": @{
                    @"id": imageID,
                    @"deletehash": @"",
                    @"account_id": [NSNull null],
                    @"account_url": [NSNull null],
                    @"ad_type": [NSNull null],
                    @"ad_url": [NSNull null],
                    @"title": [NSNull null],
                    @"description": [NSNull null],
                    @"name": @"",
                    @"type": @"image/jpeg",
                    @"width": @1920,
                    @"height": @1080,
                    @"size": @0,
                    @"views": @0,
                    @"section": [NSNull null],
                    @"vote": [NSNull null],
                    @"bandwidth": @0,
                    @"animated": @NO,
                    @"favorite": @NO,
                    @"in_gallery": @NO,
                    @"in_most_viral": @NO,
                    @"has_sound": @NO,
                    @"is_ad": @NO,
                    @"nsfw": [NSNull null],
                    @"link": ddgProxied,
                    @"datetime": @1492556556
                }
            };
            NSData *syntheticData = [NSJSONSerialization dataWithJSONObject:syntheticResponse options:0 error:nil];
            NSHTTPURLResponse *fakeHTTPResponse = [[NSHTTPURLResponse alloc] initWithURL:url
                                                                              statusCode:200
                                                                             HTTPVersion:@"HTTP/1.1"
                                                                            headerFields:@{@"Content-Type": @"application/json"}];
            void (^wrappedHandler)(NSData *, NSURLResponse *, NSError *) = ^(__unused NSData *data, __unused NSURLResponse *response, __unused NSError *error) {
                completionHandler(syntheticData, fakeHTTPResponse, nil);
            };
            return %orig(ApolloLocalFastFailRequest(@"apollo-imgur-image"), wrappedHandler);
        }
    }
    return %orig(url, ApolloDeletedCommentsMaybeWrapCompletionURL(url, completionHandler));
}

%end
