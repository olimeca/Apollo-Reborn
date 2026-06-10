#import "ApolloDeletedCommentsData.h"

#import <objc/message.h>
#import <objc/runtime.h>

#ifdef APOLLO_DELETED_COMMENTS_TESTING
#define ApolloLog(fmt, ...) NSLog((fmt), ##__VA_ARGS__)
BOOL sShowDeletedComments = YES;
BOOL sTapToRevealDeletedComments = NO;
#else
#import "ApolloCommon.h"
#import "ApolloState.h"
#endif

NSString *const ApolloDeletedCommentsObservedThreadNotification = @"ApolloDeletedCommentsObservedThreadNotification";

static const void *kApolloDeletedCommentsResponseDataKey = &kApolloDeletedCommentsResponseDataKey;
static NSMutableSet<NSString *> *sApolloDeletedCommentsDelegateTransformerInstalledClasses = nil;
static NSString *sApolloDeletedCommentsLastObservedLinkFullName = nil;
static NSDate *sApolloDeletedCommentsLastObservedLinkDate = nil;
static NSMutableDictionary<NSString *, NSString *> *sApolloDeletedCommentsRecoveredReasonsByFullName = nil;
static NSMutableSet<NSString *> *sApolloDeletedCommentsRecoveredBodyKeys = nil;
static NSMutableSet<NSString *> *sApolloDeletedCommentsRevealedFullNames = nil;
static NSMutableSet<NSString *> *sApolloDeletedCommentsRevealedBodyKeys = nil;
static NSObject *sApolloDeletedCommentsRegistryLock = nil;

static NSString *const ApolloDeletedCommentsMarkerKey = @"apollo_recovered_deleted_comment";
static NSString *const ApolloDeletedCommentsReasonKey = @"apollo_recovered_deleted_reason";
static NSString *const ApolloDeletedCommentsReasonUserDeleted = @"user_deleted";
static NSString *const ApolloDeletedCommentsReasonModeratorRemoved = @"moderator_removed";

static NSString *ApolloDeletedCommentsTrimmedString(NSString *s);
static NSString *ApolloDeletedCommentsUnescapedHTMLText(NSString *s);
static BOOL ApolloDeletedCommentsIsRedditHost(NSString *host);

#pragma mark - RecoveredCommentRegistry

static NSObject *ApolloDeletedCommentsRegistryLock(void) {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        sApolloDeletedCommentsRegistryLock = [NSObject new];
    });
    return sApolloDeletedCommentsRegistryLock;
}

static NSString *ApolloDeletedCommentsRegistryBodyKey(NSString *author, NSString *body) {
    NSString *trimmedBody = ApolloDeletedCommentsTrimmedString(body);
    if (trimmedBody.length == 0) return nil;
    NSString *trimmedAuthor = ApolloDeletedCommentsTrimmedString(author) ?: @"";
    return [NSString stringWithFormat:@"%@\n%lu\n%@", trimmedAuthor, (unsigned long)trimmedBody.length, trimmedBody];
}

void ApolloDeletedCommentsRegisterRecoveredComment(NSString *fullName, NSString *reason) {
    if (![fullName isKindOfClass:[NSString class]] || fullName.length == 0) return;
    @synchronized(ApolloDeletedCommentsRegistryLock()) {
        if (!sApolloDeletedCommentsRecoveredReasonsByFullName) {
            sApolloDeletedCommentsRecoveredReasonsByFullName = [NSMutableDictionary dictionary];
        }
        sApolloDeletedCommentsRecoveredReasonsByFullName[fullName] = reason.length > 0 ? reason : ApolloDeletedCommentsReasonModeratorRemoved;
    }
}

static void ApolloDeletedCommentsRegisterRecoveredBody(NSString *author, NSString *body) {
    NSString *key = ApolloDeletedCommentsRegistryBodyKey(author, body);
    if (key.length == 0) return;
    @synchronized(ApolloDeletedCommentsRegistryLock()) {
        if (!sApolloDeletedCommentsRecoveredBodyKeys) {
            sApolloDeletedCommentsRecoveredBodyKeys = [NSMutableSet set];
        }
        [sApolloDeletedCommentsRecoveredBodyKeys addObject:key];
    }
}

BOOL ApolloDeletedCommentsIsRecoveredComment(NSString *fullName) {
    if (![fullName isKindOfClass:[NSString class]] || fullName.length == 0) return NO;
    @synchronized(ApolloDeletedCommentsRegistryLock()) {
        return sApolloDeletedCommentsRecoveredReasonsByFullName[fullName] != nil;
    }
}

BOOL ApolloDeletedCommentsIsRecoveredCommentBody(NSString *author, NSString *body) {
    NSString *key = ApolloDeletedCommentsRegistryBodyKey(author, body);
    if (key.length == 0) return NO;
    @synchronized(ApolloDeletedCommentsRegistryLock()) {
        return [sApolloDeletedCommentsRecoveredBodyKeys containsObject:key];
    }
}

BOOL ApolloDeletedCommentsIsCommentRevealed(NSString *fullName) {
    if (![fullName isKindOfClass:[NSString class]] || fullName.length == 0) return NO;
    @synchronized(ApolloDeletedCommentsRegistryLock()) {
        return [sApolloDeletedCommentsRevealedFullNames containsObject:fullName];
    }
}

BOOL ApolloDeletedCommentsIsCommentBodyRevealed(NSString *author, NSString *body) {
    NSString *key = ApolloDeletedCommentsRegistryBodyKey(author, body);
    if (key.length == 0) return NO;
    @synchronized(ApolloDeletedCommentsRegistryLock()) {
        return [sApolloDeletedCommentsRevealedBodyKeys containsObject:key];
    }
}

void ApolloDeletedCommentsMarkCommentRevealed(NSString *fullName) {
    if (![fullName isKindOfClass:[NSString class]] || fullName.length == 0) return;
    @synchronized(ApolloDeletedCommentsRegistryLock()) {
        if (!sApolloDeletedCommentsRevealedFullNames) {
            sApolloDeletedCommentsRevealedFullNames = [NSMutableSet set];
        }
        [sApolloDeletedCommentsRevealedFullNames addObject:fullName];
    }
}

void ApolloDeletedCommentsMarkCommentBodyRevealed(NSString *author, NSString *body) {
    NSString *key = ApolloDeletedCommentsRegistryBodyKey(author, body);
    if (key.length == 0) return;
    @synchronized(ApolloDeletedCommentsRegistryLock()) {
        if (!sApolloDeletedCommentsRevealedBodyKeys) {
            sApolloDeletedCommentsRevealedBodyKeys = [NSMutableSet set];
        }
        [sApolloDeletedCommentsRevealedBodyKeys addObject:key];
    }
}

#pragma mark - RequestClassifier

static BOOL ApolloDeletedCommentsIsRedditHost(NSString *host) {
    if (!host) return NO;
    NSString *lowerHost = [host lowercaseString];
    return [lowerHost isEqualToString:@"oauth.reddit.com"] ||
           [lowerHost isEqualToString:@"www.reddit.com"] ||
           [lowerHost isEqualToString:@"old.reddit.com"] ||
           [lowerHost isEqualToString:@"reddit.com"] ||
           [lowerHost hasSuffix:@".reddit.com"];
}

static NSString *ApolloDeletedCommentsNormalizeLinkID(NSString *identifier) {
    NSString *trimmed = [identifier stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (trimmed.length == 0) return nil;
    if ([trimmed rangeOfString:@","].location != NSNotFound) return nil;
    if ([trimmed hasPrefix:@"t3_"] && trimmed.length > 3) return trimmed;
    if ([trimmed hasPrefix:@"t1_"] ||
        [trimmed hasPrefix:@"t2_"] ||
        [trimmed hasPrefix:@"t4_"] ||
        [trimmed hasPrefix:@"t5_"] ||
        [trimmed hasPrefix:@"t6_"]) return nil;
    return [@"t3_" stringByAppendingString:trimmed];
}

static NSString *ApolloDeletedCommentsLinkFullNameFromRedditURL(NSURL *url) {
    if (!url || !ApolloDeletedCommentsIsRedditHost(url.host)) return nil;

    NSURLComponents *components = [NSURLComponents componentsWithURL:url resolvingAgainstBaseURL:NO];
    for (NSURLQueryItem *item in components.queryItems ?: @[]) {
        NSString *name = [item.name lowercaseString];
        if (![name isEqualToString:@"id"] &&
            ![name isEqualToString:@"link_id"] &&
            ![name isEqualToString:@"article"] &&
            ![name isEqualToString:@"link"]) {
            continue;
        }
        NSString *fullName = ApolloDeletedCommentsNormalizeLinkID(item.value);
        if (fullName.length > 0) return fullName;
    }

    NSArray<NSString *> *parts = [url.path componentsSeparatedByString:@"/"];
    for (NSUInteger i = 0; i < parts.count; i++) {
        NSString *part = [parts[i] lowercaseString];
        if (![part isEqualToString:@"comments"] && ![part isEqualToString:@"comments.json"]) continue;
        if (i + 1 >= parts.count) continue;
        NSString *candidate = parts[i + 1];
        if ([candidate hasSuffix:@".json"]) candidate = [candidate stringByDeletingPathExtension];
        NSString *fullName = ApolloDeletedCommentsNormalizeLinkID(candidate);
        if (fullName.length > 0) return fullName;
    }
    return nil;
}

static NSString *ApolloDeletedCommentsRecentObservedLinkFullName(void) {
    if (sApolloDeletedCommentsLastObservedLinkFullName.length == 0 || !sApolloDeletedCommentsLastObservedLinkDate) return nil;
    if ([[NSDate date] timeIntervalSinceDate:sApolloDeletedCommentsLastObservedLinkDate] > 45.0) return nil;
    return sApolloDeletedCommentsLastObservedLinkFullName;
}

static NSString *ApolloDeletedCommentsLinkFullNameForRequest(NSURLRequest *request) {
    if (!ApolloDeletedCommentsIsRedditHost(request.URL.host)) return nil;
    NSString *fullName = ApolloDeletedCommentsLinkFullNameFromRedditURL(request.URL);
    if (fullName.length > 0) return fullName;
    return ApolloDeletedCommentsRecentObservedLinkFullName();
}

static BOOL ApolloDeletedCommentsRequestLooksLikeCommentsPayload(NSURLRequest *request) {
    NSURL *url = request.URL;
    if (!url || !ApolloDeletedCommentsIsRedditHost(url.host)) return NO;

    NSString *path = [[url path] lowercaseString] ?: @"";
    if ([path rangeOfString:@"/comments/"].location != NSNotFound ||
        [path hasSuffix:@"/comments.json"] ||
        [path rangeOfString:@"/api/morechildren"].location != NSNotFound) {
        return YES;
    }

    return NO;
}

static BOOL ApolloDeletedCommentsIsMoreChildrenRequest(NSURLRequest *request) {
    if (!ApolloDeletedCommentsIsRedditHost(request.URL.host)) return NO;
    NSString *path = [[request.URL path] lowercaseString] ?: @"";
    return [path rangeOfString:@"/api/morechildren"].location != NSNotFound;
}

static BOOL ApolloDeletedCommentsShouldTransformRequest(NSURLRequest *request) {
    if (!sShowDeletedComments || !request.URL || !ApolloDeletedCommentsIsRedditHost(request.URL.host)) return NO;
    if (!ApolloDeletedCommentsRequestLooksLikeCommentsPayload(request)) return NO;
    return ApolloDeletedCommentsLinkFullNameForRequest(request).length > 0;
}

void ApolloDeletedCommentsHandleRequestObservation(NSURLRequest *request, NSString *source) {
    if (!sShowDeletedComments || !ApolloDeletedCommentsIsRedditHost(request.URL.host)) return;
    NSString *fullName = ApolloDeletedCommentsLinkFullNameFromRedditURL(request.URL);
    if (fullName.length == 0) return;

    BOOL changed = ![sApolloDeletedCommentsLastObservedLinkFullName isEqualToString:fullName];
    sApolloDeletedCommentsLastObservedLinkFullName = [fullName copy];
    sApolloDeletedCommentsLastObservedLinkDate = [NSDate date];
    if (changed) {
        ApolloLog(@"[DeletedComments] Observed Reddit comments request %@ (%@)", fullName, source ?: @"unknown");
    }

    dispatch_async(dispatch_get_main_queue(), ^{
        [[NSNotificationCenter defaultCenter] postNotificationName:ApolloDeletedCommentsObservedThreadNotification
                                                            object:nil
                                                          userInfo:@{@"fullName": fullName}];
    });
}

#pragma mark - RecoveredCommentPolicy

static NSString *ApolloDeletedCommentsTrimmedString(NSString *s) {
    if (![s isKindOfClass:[NSString class]]) return nil;
    return [s stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
}

static BOOL ApolloDeletedCommentsBodyLooksDeleted(NSString *body) {
    NSString *trimmed = [[ApolloDeletedCommentsTrimmedString(body) ?: @"" lowercaseString] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (trimmed.length == 0) return YES;
    if ([trimmed isEqualToString:@"[deleted]"]) return YES;
    if ([trimmed isEqualToString:@"[removed]"]) return YES;
    if ([trimmed isEqualToString:@"deleted"]) return YES;
    if ([trimmed isEqualToString:@"removed"]) return YES;
    if ([trimmed isEqualToString:@"removed by moderator"]) return YES;
    if ([trimmed isEqualToString:@"removed by mod"]) return YES;
    if ([trimmed isEqualToString:@"removed by reddit"]) return YES;
    if ([trimmed isEqualToString:@"comment removed by moderator"]) return YES;
    if ([trimmed isEqualToString:@"comment removed by reddit"]) return YES;
    if ([trimmed isEqualToString:@"user deleted comment :("]) return YES;
    if ([trimmed isEqualToString:@"user deleted comment"]) return YES;
    if ([trimmed rangeOfString:@"removed by moderator"].location != NSNotFound && trimmed.length < 80) return YES;
    if ([trimmed rangeOfString:@"user deleted comment"].location != NSNotFound && trimmed.length < 80) return YES;
    return NO;
}

static BOOL ApolloDeletedCommentsCommentDataLooksDeleted(NSDictionary *data) {
    if (![data isKindOfClass:[NSDictionary class]]) return NO;
    NSString *body = [data[@"body"] isKindOfClass:[NSString class]] ? data[@"body"] : nil;
    if (ApolloDeletedCommentsBodyLooksDeleted(body)) return YES;

    NSString *bodyHTML = [data[@"body_html"] isKindOfClass:[NSString class]] ? data[@"body_html"] : nil;
    if (bodyHTML.length == 0) return NO;
    NSString *htmlText = ApolloDeletedCommentsUnescapedHTMLText(bodyHTML);
    return [htmlText rangeOfString:@"[removed]" options:NSCaseInsensitiveSearch].location != NSNotFound ||
           [htmlText rangeOfString:@"[deleted]" options:NSCaseInsensitiveSearch].location != NSNotFound ||
           [htmlText rangeOfString:@"Removed by moderator" options:NSCaseInsensitiveSearch].location != NSNotFound ||
           [htmlText rangeOfString:@"User deleted comment" options:NSCaseInsensitiveSearch].location != NSNotFound;
}

static NSString *ApolloDeletedCommentsCommentFullName(NSDictionary *data) {
    if (![data isKindOfClass:[NSDictionary class]]) return nil;
    NSString *name = [data[@"name"] isKindOfClass:[NSString class]] ? data[@"name"] : nil;
    if ([name hasPrefix:@"t1_"]) return name;
    NSString *identifier = [data[@"id"] isKindOfClass:[NSString class]] ? data[@"id"] : nil;
    if (identifier.length == 0) return nil;
    return [identifier hasPrefix:@"t1_"] ? identifier : [@"t1_" stringByAppendingString:identifier];
}

static NSArray<NSString *> *ApolloDeletedCommentsSplitIDs(NSString *value) {
    if (![value isKindOfClass:[NSString class]] || value.length == 0) return @[];

    NSMutableArray<NSString *> *fullNames = [NSMutableArray array];
    NSArray<NSString *> *parts = [value componentsSeparatedByString:@","];
    for (NSString *part in parts) {
        NSString *identifier = [part stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
        if (identifier.length == 0) continue;
        NSString *fullName = [identifier hasPrefix:@"t1_"] ? identifier : [@"t1_" stringByAppendingString:identifier];
        [fullNames addObject:fullName];
    }
    return fullNames;
}

static void ApolloDeletedCommentsAddFormValue(NSMutableDictionary<NSString *, NSMutableArray<NSString *> *> *params, NSString *name, NSString *value) {
    if (name.length == 0 || value.length == 0) return;
    NSString *decodedName = [name stringByRemovingPercentEncoding] ?: name;
    NSString *decodedValue = [value stringByRemovingPercentEncoding] ?: value;
    if (!params[decodedName]) params[decodedName] = [NSMutableArray array];
    [params[decodedName] addObject:decodedValue];
}

static NSDictionary<NSString *, NSArray<NSString *> *> *ApolloDeletedCommentsRequestParameters(NSURLRequest *request) {
    NSMutableDictionary<NSString *, NSMutableArray<NSString *> *> *params = [NSMutableDictionary dictionary];

    NSURLComponents *components = [NSURLComponents componentsWithURL:request.URL resolvingAgainstBaseURL:NO];
    for (NSURLQueryItem *item in components.queryItems ?: @[]) {
        ApolloDeletedCommentsAddFormValue(params, item.name, item.value);
    }

    NSData *body = request.HTTPBody;
    if (body.length > 0) {
        NSString *bodyString = [[NSString alloc] initWithData:body encoding:NSUTF8StringEncoding];
        for (NSString *pair in [bodyString componentsSeparatedByString:@"&"]) {
            if (pair.length == 0) continue;
            NSRange separator = [pair rangeOfString:@"="];
            NSString *name = separator.location == NSNotFound ? pair : [pair substringToIndex:separator.location];
            NSString *value = separator.location == NSNotFound ? @"" : [pair substringFromIndex:separator.location + 1];
            ApolloDeletedCommentsAddFormValue(params, name, value);
        }
    }

    NSMutableDictionary<NSString *, NSArray<NSString *> *> *immutableParams = [NSMutableDictionary dictionary];
    for (NSString *key in params) immutableParams[key] = [params[key] copy];
    return immutableParams;
}

static NSArray<NSString *> *ApolloDeletedCommentsRequestedMoreChildren(NSURLRequest *request) {
    if (!ApolloDeletedCommentsIsMoreChildrenRequest(request)) return @[];

    NSDictionary<NSString *, NSArray<NSString *> *> *params = ApolloDeletedCommentsRequestParameters(request);
    NSMutableArray<NSString *> *fullNames = [NSMutableArray array];
    for (NSString *value in params[@"children"] ?: @[]) {
        [fullNames addObjectsFromArray:ApolloDeletedCommentsSplitIDs(value)];
    }
    return fullNames;
}

static NSString *ApolloDeletedCommentsEscapeHTML(NSString *s) {
    NSMutableString *escaped = [s ?: @"" mutableCopy];
    [escaped replaceOccurrencesOfString:@"&" withString:@"&amp;" options:0 range:NSMakeRange(0, escaped.length)];
    [escaped replaceOccurrencesOfString:@"<" withString:@"&lt;" options:0 range:NSMakeRange(0, escaped.length)];
    [escaped replaceOccurrencesOfString:@">" withString:@"&gt;" options:0 range:NSMakeRange(0, escaped.length)];
    [escaped replaceOccurrencesOfString:@"\"" withString:@"&quot;" options:0 range:NSMakeRange(0, escaped.length)];
    return escaped;
}

static NSString *ApolloDeletedCommentsUnescapedHTMLText(NSString *s) {
    NSMutableString *text = [s ?: @"" mutableCopy];
    [text replaceOccurrencesOfString:@"&lt;" withString:@"<" options:0 range:NSMakeRange(0, text.length)];
    [text replaceOccurrencesOfString:@"&gt;" withString:@">" options:0 range:NSMakeRange(0, text.length)];
    [text replaceOccurrencesOfString:@"&quot;" withString:@"\"" options:0 range:NSMakeRange(0, text.length)];
    [text replaceOccurrencesOfString:@"&#39;" withString:@"'" options:0 range:NSMakeRange(0, text.length)];
    [text replaceOccurrencesOfString:@"&amp;" withString:@"&" options:0 range:NSMakeRange(0, text.length)];
    return text;
}

static BOOL ApolloDeletedCommentsBodyLooksUserDeleted(NSString *body) {
    NSString *trimmed = [[ApolloDeletedCommentsTrimmedString(body) ?: @"" lowercaseString] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if ([trimmed isEqualToString:@"[deleted]"]) return YES;
    if ([trimmed isEqualToString:@"deleted"]) return YES;
    if ([trimmed isEqualToString:@"user deleted comment :("]) return YES;
    if ([trimmed rangeOfString:@"user deleted comment"].location != NSNotFound) return YES;
    return NO;
}

static BOOL ApolloDeletedCommentsArchivedWasDeleted(NSDictionary *archived) {
    if (![archived isKindOfClass:[NSDictionary class]]) return NO;
    NSDictionary *metadata = [archived[@"_meta"] isKindOfClass:[NSDictionary class]] ? archived[@"_meta"] : nil;
    if ([metadata[@"was_deleted_later"] respondsToSelector:@selector(boolValue)] && [metadata[@"was_deleted_later"] boolValue]) return YES;
    NSString *removalType = [metadata[@"removal_type"] isKindOfClass:[NSString class]] ? metadata[@"removal_type"] : nil;
    if (removalType.length > 0) return YES;
    NSString *removedByCategory = [archived[@"removed_by_category"] isKindOfClass:[NSString class]] ? archived[@"removed_by_category"] : nil;
    if (removedByCategory.length > 0) return YES;
    if (archived[@"banned_by"] && archived[@"banned_by"] != (id)[NSNull null]) return YES;
    return NO;
}

static BOOL ApolloDeletedCommentsArchivedIsRecoverableDeleted(NSDictionary *archived) {
    if (!ApolloDeletedCommentsArchivedWasDeleted(archived)) return NO;
    NSString *body = ApolloDeletedCommentsTrimmedString([archived[@"body"] isKindOfClass:[NSString class]] ? archived[@"body"] : nil);
    return body.length > 0 && !ApolloDeletedCommentsBodyLooksDeleted(body);
}

static NSString *ApolloDeletedCommentsReasonForCurrentBody(NSString *body, NSString *bodyHTML) {
    if (ApolloDeletedCommentsBodyLooksUserDeleted(body)) return ApolloDeletedCommentsReasonUserDeleted;
    if (ApolloDeletedCommentsBodyLooksUserDeleted(ApolloDeletedCommentsUnescapedHTMLText(bodyHTML))) return ApolloDeletedCommentsReasonUserDeleted;
    return ApolloDeletedCommentsReasonModeratorRemoved;
}

static NSString *ApolloDeletedCommentsReasonForArchived(NSDictionary *archived) {
    NSDictionary *metadata = [archived[@"_meta"] isKindOfClass:[NSDictionary class]] ? archived[@"_meta"] : nil;
    NSString *removalType = [metadata[@"removal_type"] isKindOfClass:[NSString class]] ? [metadata[@"removal_type"] lowercaseString] : nil;
    if ([removalType rangeOfString:@"delete"].location != NSNotFound) return ApolloDeletedCommentsReasonUserDeleted;
    return ApolloDeletedCommentsReasonModeratorRemoved;
}

static NSString *ApolloDeletedCommentsBadgeLabelForReason(NSString *reason) {
    if ([reason isEqualToString:ApolloDeletedCommentsReasonUserDeleted]) return @"deleted by user";
    return @"removed by mod";
}

static NSString *ApolloDeletedCommentsRedditBodyHTML(NSString *body) {
    NSString *trimmed = ApolloDeletedCommentsTrimmedString(body);
    if (trimmed.length == 0) return nil;

    NSMutableArray<NSString *> *htmlParagraphs = [NSMutableArray array];
    for (NSString *paragraph in [trimmed componentsSeparatedByString:@"\n\n"]) {
        NSString *p = ApolloDeletedCommentsTrimmedString(paragraph);
        if (p.length == 0) continue;
        NSString *escaped = ApolloDeletedCommentsEscapeHTML(p);
        escaped = [escaped stringByReplacingOccurrencesOfString:@"\n" withString:@"<br/>"];
        [htmlParagraphs addObject:[NSString stringWithFormat:@"<p>%@</p>", escaped]];
    }
    if (htmlParagraphs.count == 0) return nil;

    NSString *html = [NSString stringWithFormat:@"<div class=\"md\">%@\n</div>", [htmlParagraphs componentsJoinedByString:@"\n"]];
    return ApolloDeletedCommentsEscapeHTML(html);
}

static NSString *ApolloDeletedCommentsSpoilerMarkdownBody(NSString *body) {
    NSString *trimmed = ApolloDeletedCommentsTrimmedString(body);
    if (trimmed.length == 0) return nil;
    return [NSString stringWithFormat:@">!%@!<", trimmed];
}

static NSString *ApolloDeletedCommentsRedditSpoilerBodyHTML(NSString *body) {
    NSString *trimmed = ApolloDeletedCommentsTrimmedString(body);
    if (trimmed.length == 0) return nil;

    NSString *escaped = ApolloDeletedCommentsEscapeHTML(trimmed);
    escaped = [escaped stringByReplacingOccurrencesOfString:@"\n" withString:@"<br/>"];
    return [NSString stringWithFormat:@"<div class=\"md\"><p><span class=\"md-spoiler-text\">%@</span></p>\n</div>", escaped];
}

static void ApolloDeletedCommentsSetRecoveredBody(NSMutableDictionary *data, NSString *body) {
    NSString *trimmed = ApolloDeletedCommentsTrimmedString(body);
    if (trimmed.length == 0) return;

    NSString *displayBody = sTapToRevealDeletedComments ? ApolloDeletedCommentsSpoilerMarkdownBody(trimmed) : trimmed;
    data[@"body"] = displayBody.length > 0 ? displayBody : trimmed;

    NSString *bodyHTML = sTapToRevealDeletedComments ? ApolloDeletedCommentsRedditSpoilerBodyHTML(trimmed) : ApolloDeletedCommentsRedditBodyHTML(trimmed);
    if (bodyHTML.length > 0) data[@"body_html"] = bodyHTML;
}

static void ApolloDeletedCommentsApplyNeutralVoteMetadata(NSMutableDictionary *data) {
    data[@"likes"] = [NSNull null];
    data[@"vote"] = [NSNull null];
    data[@"user_vote"] = @0;
    data[@"voted"] = @NO;
}

static void ApolloDeletedCommentsApplyRecoveredMetadata(NSMutableDictionary *data, NSString *reason) {
    NSString *label = ApolloDeletedCommentsBadgeLabelForReason(reason);
    NSString *fullName = ApolloDeletedCommentsCommentFullName(data);
    NSString *author = [data[@"author"] isKindOfClass:[NSString class]] ? data[@"author"] : nil;
    NSString *body = [data[@"body"] isKindOfClass:[NSString class]] ? data[@"body"] : nil;
    data[ApolloDeletedCommentsMarkerKey] = @YES;
    data[ApolloDeletedCommentsReasonKey] = reason.length > 0 ? reason : ApolloDeletedCommentsReasonModeratorRemoved;
    data[@"author_flair_text"] = label.length > 0 ? label : @"removed by mod";
    data[@"author_flair_css_class"] = @"recovered-deleted";
    data[@"author_flair_type"] = @"text";
    data[@"author_flair_richtext"] = @[];
    ApolloDeletedCommentsApplyNeutralVoteMetadata(data);
    ApolloDeletedCommentsRegisterRecoveredComment(fullName, reason);
    ApolloDeletedCommentsRegisterRecoveredBody(author, body);
}

static void ApolloDeletedCommentsClearRemovalMetadata(NSMutableDictionary *data) {
    [data removeObjectForKey:@"removed_by_category"];
    [data removeObjectForKey:@"banned_by"];
    [data removeObjectForKey:@"approved_by"];
    [data removeObjectForKey:@"mod_note"];
    [data removeObjectForKey:@"mod_reason_by"];
    [data removeObjectForKey:@"mod_reason_title"];
    [data removeObjectForKey:@"removal_reason"];
    [data removeObjectForKey:@"ban_note"];
    [data removeObjectForKey:@"ban_info"];

    data[@"collapsed"] = @NO;
    data[@"collapsed_because_crowd_control"] = @NO;
    data[@"collapsed_reason"] = [NSNull null];
    data[@"collapsed_reason_code"] = [NSNull null];
}

static void ApolloDeletedCommentsFlattenArcticChildren(NSArray *children, NSMutableDictionary<NSString *, NSDictionary *> *commentsByFullName) {
    if (![children isKindOfClass:[NSArray class]]) return;
    for (id child in children) {
        if (![child isKindOfClass:[NSDictionary class]]) continue;
        NSDictionary *entry = (NSDictionary *)child;
        NSString *kind = [entry[@"kind"] isKindOfClass:[NSString class]] ? entry[@"kind"] : nil;
        NSDictionary *data = [entry[@"data"] isKindOfClass:[NSDictionary class]] ? entry[@"data"] : nil;
        if (![kind isEqualToString:@"t1"] || !data) continue;

        NSString *fullName = ApolloDeletedCommentsCommentFullName(data);
        if (fullName.length > 0) commentsByFullName[fullName] = data;

        NSDictionary *replies = [data[@"replies"] isKindOfClass:[NSDictionary class]] ? data[@"replies"] : nil;
        NSDictionary *replyData = [replies[@"data"] isKindOfClass:[NSDictionary class]] ? replies[@"data"] : nil;
        NSArray *replyChildren = [replyData[@"children"] isKindOfClass:[NSArray class]] ? replyData[@"children"] : nil;
        ApolloDeletedCommentsFlattenArcticChildren(replyChildren, commentsByFullName);
    }
}

static NSDictionary<NSString *, NSDictionary *> *ApolloDeletedCommentsArcticCommentMapFromRoot(id root) {
    NSArray *children = nil;
    if ([root isKindOfClass:[NSDictionary class]]) {
        id data = ((NSDictionary *)root)[@"data"];
        if ([data isKindOfClass:[NSArray class]]) {
            children = data;
        } else if ([data isKindOfClass:[NSDictionary class]]) {
            id listingChildren = ((NSDictionary *)data)[@"children"];
            if ([listingChildren isKindOfClass:[NSArray class]]) children = listingChildren;
        }
    }
    if (![children isKindOfClass:[NSArray class]]) return nil;

    NSMutableDictionary *comments = [NSMutableDictionary dictionary];
    ApolloDeletedCommentsFlattenArcticChildren(children, comments);
    return comments.count > 0 ? comments : nil;
}

static NSDictionary<NSString *, NSDictionary *> *ApolloDeletedCommentsArcticCommentMapFromFlatData(id root) {
    NSArray *commentsArray = nil;
    if ([root isKindOfClass:[NSDictionary class]]) {
        id data = ((NSDictionary *)root)[@"data"];
        if ([data isKindOfClass:[NSArray class]]) commentsArray = data;
    } else if ([root isKindOfClass:[NSArray class]]) {
        commentsArray = root;
    }
    if (![commentsArray isKindOfClass:[NSArray class]]) return nil;

    NSMutableDictionary *comments = [NSMutableDictionary dictionary];
    for (id entry in commentsArray) {
        if (![entry isKindOfClass:[NSDictionary class]]) continue;
        NSString *fullName = ApolloDeletedCommentsCommentFullName(entry);
        if (fullName.length > 0) comments[fullName] = entry;
    }
    return comments.count > 0 ? comments : nil;
}

static void ApolloDeletedCommentsFetchArcticComments(NSString *linkFullName, void (^completion)(NSDictionary<NSString *, NSDictionary *> *comments)) {
    if (linkFullName.length == 0) {
        completion(nil);
        return;
    }

    NSURLComponents *components = [NSURLComponents componentsWithString:@"https://arctic-shift.photon-reddit.com/api/comments/tree"];
    components.queryItems = @[
        [NSURLQueryItem queryItemWithName:@"link_id" value:linkFullName],
        [NSURLQueryItem queryItemWithName:@"limit" value:@"25000"],
        [NSURLQueryItem queryItemWithName:@"start_depth" value:@"99"],
        [NSURLQueryItem queryItemWithName:@"start_breadth" value:@"99"],
        [NSURLQueryItem queryItemWithName:@"md2html" value:@"false"],
    ];
    NSURL *url = components.URL;
    if (!url) {
        completion(nil);
        return;
    }

    NSURLSessionDataTask *task = [[NSURLSession sharedSession] dataTaskWithURL:url completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        NSDictionary *comments = nil;
        if (!error && data.length > 0) {
            NSHTTPURLResponse *http = [response isKindOfClass:[NSHTTPURLResponse class]] ? (NSHTTPURLResponse *)response : nil;
            if (!http || (http.statusCode >= 200 && http.statusCode < 300)) {
                id root = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
                comments = ApolloDeletedCommentsArcticCommentMapFromRoot(root);
            }
        }
        completion(comments);
    }];
    [task resume];
}

static NSArray<NSArray<NSString *> *> *ApolloDeletedCommentsBatches(NSArray<NSString *> *values, NSUInteger batchSize) {
    if (values.count == 0 || batchSize == 0) return @[];
    NSMutableArray *batches = [NSMutableArray array];
    for (NSUInteger i = 0; i < values.count; i += batchSize) {
        NSUInteger count = MIN(batchSize, values.count - i);
        [batches addObject:[values subarrayWithRange:NSMakeRange(i, count)]];
    }
    return batches;
}

static void ApolloDeletedCommentsFetchArcticCommentsByFullNames(NSArray<NSString *> *fullNames,
                                                                void (^completion)(NSDictionary<NSString *, NSDictionary *> *comments)) {
    if (fullNames.count == 0) {
        completion(@{});
        return;
    }

    NSMutableOrderedSet<NSString *> *baseIDs = [NSMutableOrderedSet orderedSet];
    for (NSString *fullName in fullNames) {
        if (![fullName isKindOfClass:[NSString class]] || ![fullName hasPrefix:@"t1_"] || fullName.length <= 3) continue;
        [baseIDs addObject:[fullName substringFromIndex:3]];
    }
    if (baseIDs.count == 0) {
        completion(@{});
        return;
    }

    NSArray<NSArray<NSString *> *> *batches = ApolloDeletedCommentsBatches(baseIDs.array, 250);
    NSMutableDictionary<NSString *, NSDictionary *> *merged = [NSMutableDictionary dictionary];
    
    __block __weak void (^weakFetchNext)(void);
    __block NSUInteger nextIndex = 0;
    
    void (^fetchNext)(void) = ^{
        if (nextIndex >= batches.count) {
            completion([merged copy]);
            return;
        }

        NSArray<NSString *> *batch = batches[nextIndex++];
        NSURLComponents *components = [NSURLComponents componentsWithString:@"https://arctic-shift.photon-reddit.com/api/comments/ids"];
        components.queryItems = @[
            [NSURLQueryItem queryItemWithName:@"ids" value:[batch componentsJoinedByString:@","]],
            [NSURLQueryItem queryItemWithName:@"md2html" value:@"false"],
        ];
        NSURL *url = components.URL;
        if (!url) {
            if (weakFetchNext) weakFetchNext();
            return;
        }

        NSURLSessionDataTask *task = [[NSURLSession sharedSession] dataTaskWithURL:url completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
            if (!error && data.length > 0) {
                NSHTTPURLResponse *http = [response isKindOfClass:[NSHTTPURLResponse class]] ? (NSHTTPURLResponse *)response : nil;
                if (!http || (http.statusCode >= 200 && http.statusCode < 300)) {
                    id root = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
                    NSDictionary *parsedBatch = ApolloDeletedCommentsArcticCommentMapFromFlatData(root);
                    if (parsedBatch) {
                        [merged addEntriesFromDictionary:parsedBatch];
                    }
                }
            }
            if (weakFetchNext) weakFetchNext();
        }];
        [task resume];
    };

    weakFetchNext = fetchNext;
    fetchNext();
}
