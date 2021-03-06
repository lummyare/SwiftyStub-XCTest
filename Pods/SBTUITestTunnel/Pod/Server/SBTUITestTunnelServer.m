// SBTUITestTunnelServer.m
//
// Copyright (C) 2016 Subito.it S.r.l (www.subito.it)
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
// http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.

#if DEBUG
    #ifndef ENABLE_UITUNNEL 
        #define ENABLE_UITUNNEL 1
    #endif
#endif

#if ENABLE_UITUNNEL

#import "SBTUITestTunnelServer.h"
#import "SBTUITestTunnel.h"
#import "NSURLRequest+SBTUITestTunnelMatch.h"
#import "UITextField+DisableAutocomplete.h"
#import "SBTProxyURLProtocol.h"
#import "SBTProxyStubResponse.h"
#import "SBTMonitoredNetworkRequest.h"
#import <GCDWebServer/GCDWebServer.h>
#import <GCDWebServer/GCDWebServerURLEncodedFormRequest.h>
#import <GCDWebServer/GCDWebServerDataResponse.h>
#import "NSData+SHA1.h"
#import <CoreLocation/CoreLocation.h>

#if !defined(NS_BLOCK_ASSERTIONS)

#define BlockAssert(condition, desc, ...) \
do {\
if (!(condition)) { \
[[NSAssertionHandler currentHandler] handleFailureInFunction:NSStringFromSelector(_cmd) \
file:[NSString stringWithUTF8String:__FILE__] \
lineNumber:__LINE__ \
description:(desc), ##__VA_ARGS__]; \
}\
} while(0);

#else // NS_BLOCK_ASSERTIONS defined

#define BlockAssert(condition, desc, ...)

#endif

@implementation GCDWebServerRequest (Extension)

- (NSDictionary *)parameters
{
    if ([self isKindOfClass:[GCDWebServerURLEncodedFormRequest class]]) {
        return ((GCDWebServerURLEncodedFormRequest *)self).arguments;
    } else {
        return self.query;
    }
}

@end

@interface SBTUITestTunnelServer()

@property (nonatomic, strong) GCDWebServer *server;
@property (nonatomic, strong) NSCountedSet<NSString *> *stubsToRemoveAfterCount;
@property (nonatomic, strong) NSMutableArray<SBTMonitoredNetworkRequest *> *monitoredRequests;
@property (nonatomic, strong) dispatch_queue_t commandDispatchQueue;
@property (nonatomic, strong) NSLock *startupCommandsCompletedLock;
@property (nonatomic, assign) BOOL startupCommandsCompleted;
@property (nonatomic, strong) NSMutableDictionary<NSString *, void (^)(NSObject *)> *customCommands;
@property (nonatomic, assign) BOOL cruising;

@end

@implementation SBTUITestTunnelServer

+ (SBTUITestTunnelServer *)sharedInstance
{
    static dispatch_once_t once;
    static SBTUITestTunnelServer *sharedInstance;
    dispatch_once(&once, ^{
        sharedInstance = [[SBTUITestTunnelServer alloc] init];
        sharedInstance.server = [[GCDWebServer alloc] init];
        sharedInstance.stubsToRemoveAfterCount = [NSCountedSet set];
        sharedInstance.monitoredRequests = [NSMutableArray array];
        sharedInstance.commandDispatchQueue = dispatch_queue_create("com.sbtuitesttunnel.queue.command", DISPATCH_QUEUE_SERIAL);
        sharedInstance.startupCommandsCompletedLock = [[NSLock alloc] init];
        sharedInstance.startupCommandsCompleted = NO;
        sharedInstance.cruising = YES;
    });
    return sharedInstance;
}

+ (void)takeOff
{
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        [self.sharedInstance takeOffOnce];
    });
}

- (void)takeOffOnce
{
    NSDictionary<NSString *, NSString *> *environment = [NSProcessInfo processInfo].environment;
    NSString *bonjourName = environment[SBTUITunneledApplicationLaunchEnvironmentBonjourNameKey];
    
    if (!bonjourName) {
        // Required methods missing, presumely app wasn't launched from ui test
        NSLog(@"[UITestTunnelServer] required environment parameters missing, safely landing");
        return;
    }
    
    [NSURLProtocol registerClass:[SBTProxyURLProtocol class]];
    
    Class requestClass = ([SBTUITunnelHTTPMethod isEqualToString:@"POST"]) ? [GCDWebServerURLEncodedFormRequest class] : [GCDWebServerRequest class];
    
    __weak typeof(self) weakSelf = self;
    [self.server addDefaultHandlerForMethod:SBTUITunnelHTTPMethod requestClass:requestClass processBlock:^GCDWebServerResponse *(GCDWebServerRequest* request) {
        __block GCDWebServerDataResponse *ret;
        
        dispatch_semaphore_t sem = dispatch_semaphore_create(0);
        dispatch_async(weakSelf.commandDispatchQueue, ^{
            __strong typeof(weakSelf)strongSelf = weakSelf;
            NSLog(@"[UITestTunnelServer] received command %@", request.path);
            
            NSString *command = [request.path stringByReplacingOccurrencesOfString:@"/" withString:@""];
            
            NSString *commandString = [command stringByAppendingString:@":"];
            SEL commandSelector = NSSelectorFromString(commandString);
            NSDictionary *response = nil;
            
            if (![weakSelf processCustomCommandIfNecessary:request returnObject:&response]) {
                if (![strongSelf respondsToSelector:commandSelector]) {
                    BlockAssert(NO, @"[UITestTunnelServer] Unhandled/unknown command! %@", command);
                }
                
                IMP imp = [strongSelf methodForSelector:commandSelector];
                
                NSDictionary * (*func)(id, SEL, GCDWebServerRequest *) = (void *)imp;
                response = func(strongSelf, commandSelector, request);
            }
            
            ret = [GCDWebServerDataResponse responseWithJSONObject:response];
            
            dispatch_semaphore_signal(sem);
        });
        
        dispatch_semaphore_wait(sem, DISPATCH_TIME_FOREVER);
        return ret;
    }];
    
    [self processLaunchOptionsIfNeeded];
    
    if (![[NSProcessInfo processInfo].arguments containsObject:SBTUITunneledApplicationLaunchSignal]) {
        NSLog(@"[UITestTunnelServer] Signal launch option missing, safely landing!");
        return;
    }
    
    NSError *serverError = nil;
    NSDictionary *serverOptions = [NSMutableDictionary dictionary];
    
    [serverOptions setValue:bonjourName forKey:GCDWebServerOption_BonjourName];
    [serverOptions setValue:@"_http._tcp." forKey:GCDWebServerOption_BonjourType];
    [GCDWebServer setLogLevel:3];
    
    NSLog(@"[SBTUITestTunnel] Starting server with bonjour name: %@", bonjourName);
    
    if (![self.server startWithOptions:serverOptions error:&serverError]) {
        BlockAssert(NO, @"[UITestTunnelServer] Failed to start server. %@", serverError.description);
        return;
    }
    
    [self processStartupCommandsIfNeeded];
    
    NSLog(@"[UITestTunnelServer] Up and running!");
}

+ (void)takeOffCompleted:(BOOL)completed
{
    self.sharedInstance.cruising = completed;
}

- (BOOL)processCustomCommandIfNecessary:(GCDWebServerRequest *)request returnObject:(NSObject **)returnObject
{
    NSString *command = [request.path stringByReplacingOccurrencesOfString:@"/" withString:@""];
    
    if ([command isEqualToString:SBTUITunneledApplicationCommandCustom]) {
        NSString *customCommandName = request.parameters[SBTUITunnelCustomCommandKey];
        NSData *objData = [[NSData alloc] initWithBase64EncodedString:request.parameters[SBTUITunnelObjectKey] options:0];
        NSObject *inObj = [NSKeyedUnarchiver unarchiveObjectWithData:objData];
        
        NSObject *(^block)(NSObject *) = [[SBTUITestTunnelServer customCommands] objectForKey:customCommandName];
        if (block) {
            NSObject *outObject = block(inObj);
            
            NSData *data = [NSKeyedArchiver archivedDataWithRootObject:outObject];
            
            NSString *ret = data ? [data base64EncodedStringWithOptions:0] : @"";
            *returnObject = @{ SBTUITunnelResponseResultKey: ret };
            
            return YES;
        }
    }
    
    return NO;
}

/* Rememeber to always return something at the end of the command otherwise [self performSelector] will crash with an EXC_I386_GPFLT */

#pragma mark - Ping Command

- (NSDictionary *)commandPing:(GCDWebServerRequest *)tunnelRequest
{
    return @{ SBTUITunnelResponseResultKey: @"YES" };
}

#pragma mark - Ping Command

- (NSDictionary *)commandQuit:(GCDWebServerRequest *)tunnelRequest
{
    exit(0);
    return @{ SBTUITunnelResponseResultKey: @"YES" };
}

#pragma mark - Ready Command

- (NSDictionary *)commandCruising:(GCDWebServerRequest *)tunnelRequest
{
    return @{ SBTUITunnelResponseResultKey: self.cruising ? @"YES" : @"NO" };
}

#pragma mark - Stubs Commands

- (NSDictionary *)commandStubPathMatching:(GCDWebServerRequest *)tunnelRequest
{
    __block NSString *stubId = @"";
    SBTRequestMatch *requestMatch = nil;
    
    if ([self validStubRequest:tunnelRequest]) {
        NSData *requestMatchData = [[NSData alloc] initWithBase64EncodedString:tunnelRequest.parameters[SBTUITunnelStubQueryRuleKey] options:0];
        requestMatch = [NSKeyedUnarchiver unarchiveObjectWithData:requestMatchData];
        
        SBTProxyStubResponse *response = [self responseForStubRequest:tunnelRequest];
        NSString *requestIdentifier = [self identifierForStubRequest:tunnelRequest];
        
        __weak typeof(self)weakSelf = self;
        stubId = [SBTProxyURLProtocol stubRequestsMatching:requestMatch stubResponse:response didStubRequest:^(NSURLRequest *request) {
            __strong typeof(weakSelf)strongSelf = weakSelf;
            
            if ([strongSelf.stubsToRemoveAfterCount containsObject:requestIdentifier]) {
                [strongSelf.stubsToRemoveAfterCount removeObject:requestIdentifier];
                
                if ([strongSelf.stubsToRemoveAfterCount countForObject:requestIdentifier] == 0) {
                    [SBTProxyURLProtocol stubRequestsRemoveWithId:stubId];
                }
            }
        }];
    }
    
    return @{ SBTUITunnelResponseResultKey: stubId ?: @"", SBTUITunnelResponseDebugKey: [requestMatch description] ?: @"" };
}

#pragma mark - Stub and Remove Commands

- (NSDictionary *)commandStubAndRemovePathMatching:(GCDWebServerRequest *)tunnelRequest
{
    NSDictionary *ret = @{ SBTUITunnelResponseResultKey: @"NO" };
    NSInteger stubRequestsRemoveAfterCount = 0;
    
    if ([self validStubRequest:tunnelRequest]) {
        stubRequestsRemoveAfterCount = [tunnelRequest.parameters[SBTUITunnelStubQueryIterations] integerValue];
        
        for (NSInteger i = 0; i < stubRequestsRemoveAfterCount; i++) {
            [self.stubsToRemoveAfterCount addObject:[self identifierForStubRequest:tunnelRequest]];
        }
        
        ret = [self commandStubPathMatching:tunnelRequest];
    }
    
    return ret;
}

- (NSDictionary *)commandStubRequestsRemove:(GCDWebServerRequest *)tunnelRequest
{
    NSData *responseData = [[NSData alloc] initWithBase64EncodedString:tunnelRequest.parameters[SBTUITunnelStubQueryRuleKey] options:0];
    NSString *stubId = [NSKeyedUnarchiver unarchiveObjectWithData:responseData];
    
    NSString *ret = @"NO";
    if ([self.stubsToRemoveAfterCount countForObject:stubId] == 0) {
        ret = [SBTProxyURLProtocol stubRequestsRemoveWithId:stubId] ? @"YES" : @"NO";
    }
    
    return @{ SBTUITunnelResponseResultKey: ret };
}

- (NSDictionary *)commandStubRequestsRemoveAll:(GCDWebServerRequest *)tunnelRequest
{
    [SBTProxyURLProtocol stubRequestsRemoveAll];
    
    return @{ SBTUITunnelResponseResultKey: @"YES" };
}

#pragma mark - Request Monitor Commands

- (NSDictionary *)commandMonitorPathMatching:(GCDWebServerRequest *)tunnelRequest
{
    NSString *reqId = @"";
    SBTRequestMatch *requestMatch = nil;
    
    if ([self validMonitorRequest:tunnelRequest]) {
        NSData *requestMatchData = [[NSData alloc] initWithBase64EncodedString:tunnelRequest.parameters[SBTUITunnelProxyQueryRuleKey] options:0];
        requestMatch = [NSKeyedUnarchiver unarchiveObjectWithData:requestMatchData];
        
        reqId = [SBTProxyURLProtocol proxyRequestsMatching:requestMatch delayResponse:0.0 responseBlock:^(NSURLRequest *request, NSURLRequest *originalRequest, NSHTTPURLResponse *response, NSData *responseData, NSTimeInterval requestTime, BOOL isStubbed) {
            SBTMonitoredNetworkRequest *monitoredRequest = [[SBTMonitoredNetworkRequest alloc] init];
            
            monitoredRequest.timestamp = [[NSDate date] timeIntervalSinceReferenceDate];
            monitoredRequest.requestTime = requestTime;
            monitoredRequest.request = request;
            monitoredRequest.originalRequest = originalRequest;
            
            monitoredRequest.response = response;
            
            monitoredRequest.responseData = responseData;
            
            monitoredRequest.isStubbed = isStubbed;
            
            [self.monitoredRequests addObject:monitoredRequest];
        }];
    }
    
    return @{ SBTUITunnelResponseResultKey: reqId ?: @"", SBTUITunnelResponseDebugKey: [requestMatch description] ?: @"" };
}

- (NSDictionary *)commandMonitorRemove:(GCDWebServerRequest *)tunnelRequest
{
    NSData *responseData = [[NSData alloc] initWithBase64EncodedString:tunnelRequest.parameters[SBTUITunnelStubQueryRuleKey] options:0];
    NSString *reqId = [NSKeyedUnarchiver unarchiveObjectWithData:responseData];
    
    NSString *ret = [SBTProxyURLProtocol proxyRequestsRemoveWithId:reqId] ? @"YES" : @"NO";
    
    return @{ SBTUITunnelResponseResultKey: ret };
}

- (NSDictionary *)commandMonitorsRemoveAll:(GCDWebServerRequest *)tunnelRequest
{
    [SBTProxyURLProtocol proxyRequestsRemoveAll];
    
    return @{ SBTUITunnelResponseResultKey: @"YES" };
}

- (NSDictionary *)commandMonitorPeek:(GCDWebServerRequest *)tunnelRequest
{
    dispatch_semaphore_t sem = dispatch_semaphore_create(0);
    
    __block NSString *ret = @"";
    __block NSArray *requestsToPeek = @[];
    
    __weak typeof(self)weakSelf = self;
    dispatch_async(dispatch_get_main_queue(), ^{
        __strong typeof(weakSelf)strongSelf = weakSelf;
        
        // we use main thread to synchronize access to self.monitoredRequests
        requestsToPeek = [strongSelf.monitoredRequests copy];
        
        NSData *data = [NSKeyedArchiver archivedDataWithRootObject:requestsToPeek];
        if (data) {
            ret = [data base64EncodedStringWithOptions:0];
        }
        dispatch_semaphore_signal(sem);
    });
    
    dispatch_semaphore_wait(sem, DISPATCH_TIME_FOREVER);
    
    NSString *debugInfo = [NSString stringWithFormat:@"Found %ld monitored requests", (unsigned long)requestsToPeek.count];
    return @{ SBTUITunnelResponseResultKey: ret ?: @"", SBTUITunnelResponseDebugKey: debugInfo ?: @"" };
}

- (NSDictionary *)commandMonitorFlush:(GCDWebServerRequest *)tunnelRequest
{
    dispatch_semaphore_t sem = dispatch_semaphore_create(0);
    
    __block NSString *ret = @"";
    __block NSArray *requestsToFlush = @[];
    
    __weak typeof(self)weakSelf = self;
    dispatch_async(dispatch_get_main_queue(), ^{
        // we use main thread to synchronize access to self.monitoredRequests
        __strong typeof(weakSelf)strongSelf = weakSelf;
        
        requestsToFlush = [strongSelf.monitoredRequests copy];
        strongSelf.monitoredRequests = [NSMutableArray array];
        
        NSData *data = [NSKeyedArchiver archivedDataWithRootObject:requestsToFlush];
        if (data) {
            ret = [data base64EncodedStringWithOptions:0];
        }
        dispatch_semaphore_signal(sem);
    });
    
    dispatch_semaphore_wait(sem, DISPATCH_TIME_FOREVER);
    
    NSString *debugInfo = [NSString stringWithFormat:@"Found %ld monitored requests", (unsigned long)requestsToFlush.count];
    return @{ SBTUITunnelResponseResultKey: ret ?: @"", SBTUITunnelResponseDebugKey: debugInfo ?: @"" };
}

#pragma mark - Request Throttle Commands

- (NSDictionary *)commandThrottlePathMatching:(GCDWebServerRequest *)tunnelRequest
{
    NSString *reqId = @"";
    SBTRequestMatch *requestMatch = nil;
    
    if ([self validThrottleRequest:tunnelRequest]) {
        NSData *requestMatchData = [[NSData alloc] initWithBase64EncodedString:tunnelRequest.parameters[SBTUITunnelProxyQueryRuleKey] options:0];
        requestMatch = [NSKeyedUnarchiver unarchiveObjectWithData:requestMatchData];
        NSTimeInterval responseDelayTime = [tunnelRequest.parameters[SBTUITunnelProxyQueryResponseTimeKey] doubleValue];
        
        reqId = [SBTProxyURLProtocol proxyRequestsMatching:requestMatch delayResponse:responseDelayTime responseBlock:nil];
    }
    
    return @{ SBTUITunnelResponseResultKey: reqId ?: @"", SBTUITunnelResponseDebugKey: [requestMatch description] ?: @""};
}

- (NSDictionary *)commandThrottleRemove:(GCDWebServerRequest *)tunnelRequest
{
    NSData *responseData = [[NSData alloc] initWithBase64EncodedString:tunnelRequest.parameters[SBTUITunnelStubQueryRuleKey] options:0];
    NSString *reqId = [NSKeyedUnarchiver unarchiveObjectWithData:responseData];
    
    NSString *ret = [SBTProxyURLProtocol proxyRequestsRemoveWithId:reqId] ? @"YES" : @"NO";
    return @{ SBTUITunnelResponseResultKey: ret };
}

- (NSDictionary *)commandThrottlesRemoveAll:(GCDWebServerRequest *)tunnelRequest
{
    [SBTProxyURLProtocol proxyRequestsRemoveAll];
    
    return @{ SBTUITunnelResponseResultKey: @"YES" };
}

#pragma mark - NSUSerDefaults Commands

- (NSDictionary *)commandNSUserDefaultsSetObject:(GCDWebServerRequest *)tunnelRequest
{
    NSString *objKey = tunnelRequest.parameters[SBTUITunnelObjectKeyKey];
    NSData *objData = [[NSData alloc] initWithBase64EncodedString:tunnelRequest.parameters[SBTUITunnelObjectKey] options:0];
    id obj = [NSKeyedUnarchiver unarchiveObjectWithData:objData];
    
    NSString *ret = @"NO";
    if (objKey) {
        [[NSUserDefaults standardUserDefaults] setObject:obj forKey:objKey];
        ret = [[NSUserDefaults standardUserDefaults] synchronize] ? @"YES" : @"NO";
    }
    
    return @{ SBTUITunnelResponseResultKey: ret };
}

- (NSDictionary *)commandNSUserDefaultsRemoveObject:(GCDWebServerRequest *)tunnelRequest
{
    NSString *objKey = tunnelRequest.parameters[SBTUITunnelObjectKeyKey];
    
    NSString *ret = @"NO";
    if (objKey) {
        [[NSUserDefaults standardUserDefaults] removeObjectForKey:objKey];
        ret = [[NSUserDefaults standardUserDefaults] synchronize] ? @"YES" : @"NO";
    }
    
    return @{ SBTUITunnelResponseResultKey: ret };
}

- (NSDictionary *)commandNSUserDefaultsObject:(GCDWebServerRequest *)tunnelRequest
{
    NSString *objKey = tunnelRequest.parameters[SBTUITunnelObjectKeyKey];
    
    NSObject *obj = [[NSUserDefaults standardUserDefaults] objectForKey:objKey];
    NSData *data = [NSKeyedArchiver archivedDataWithRootObject:obj];
    NSString *ret = @"";
    if (data) {
        ret = [data base64EncodedStringWithOptions:0];
    }
    
    return @{ SBTUITunnelResponseResultKey: ret ?: @"" };
}

- (NSDictionary *)commandNSUserDefaultsReset:(GCDWebServerRequest *)tunnelRequest
{
    resetUserDefaults();
    
    return @{ SBTUITunnelResponseResultKey: @"YES" };
}

#pragma mark - NSBundle

- (NSDictionary *)commandMainBundleInfoDictionary:(GCDWebServerRequest *)tunnelRequest
{
    NSData *data = [NSKeyedArchiver archivedDataWithRootObject:[[NSBundle mainBundle] infoDictionary]];
    NSString *ret = @"";
    if (data) {
        ret = [data base64EncodedStringWithOptions:0];
    }
    
    return @{ SBTUITunnelResponseResultKey: ret ?: @"" };
}

#pragma mark - Copy Commands

- (NSDictionary *)commandUpload:(GCDWebServerRequest *)tunnelRequest
{
    NSData *fileData = [[NSData alloc] initWithBase64EncodedString:tunnelRequest.parameters[SBTUITunnelUploadDataKey] options:0];
    NSString *destPath = [NSKeyedUnarchiver unarchiveObjectWithData:[[NSData alloc] initWithBase64EncodedString:tunnelRequest.parameters[SBTUITunnelUploadDestPathKey] options:0]];
    NSSearchPathDirectory basePath = [tunnelRequest.parameters[SBTUITunnelUploadBasePathKey] intValue];
    
    NSArray *paths = NSSearchPathForDirectoriesInDomains(basePath, NSUserDomainMask, YES);
    NSString *path = [[paths firstObject] stringByAppendingPathComponent:destPath];
    
    NSError *error = nil;
    if ([[NSFileManager defaultManager] fileExistsAtPath:path]) {
        [[NSFileManager defaultManager] removeItemAtPath:path error:&error];
        
        if (error) {
            return @{ SBTUITunnelResponseResultKey: @"NO" };
        }
    }
    
    [[NSFileManager defaultManager] createDirectoryAtPath:[path stringByDeletingLastPathComponent]
                              withIntermediateDirectories:YES
                                               attributes:nil error:&error];
    if (error) {
        return @{ SBTUITunnelResponseResultKey: @"NO" };
    }
    
    
    NSString *ret = [fileData writeToFile:path atomically:YES] ? @"YES" : @"NO";
    
    NSString *debugInfo = [NSString stringWithFormat:@"Writing %ld bytes to file %@", (unsigned long)fileData.length, path ?: @""];
    return @{ SBTUITunnelResponseResultKey: ret, SBTUITunnelResponseDebugKey: debugInfo };
}

- (NSDictionary *)commandDownload:(GCDWebServerRequest *)tunnelRequest
{
    NSSearchPathDirectory basePathDirectory = [tunnelRequest.parameters[SBTUITunnelDownloadBasePathKey] intValue];
    
    NSString *basePath = [NSSearchPathForDirectoriesInDomains(basePathDirectory, NSUserDomainMask, YES) firstObject];
    
    NSArray *basePathContent = [[NSFileManager defaultManager] contentsOfDirectoryAtPath:basePath error:nil];
    
    NSString *filesToMatch = [NSKeyedUnarchiver unarchiveObjectWithData:[[NSData alloc] initWithBase64EncodedString:tunnelRequest.parameters[SBTUITunnelDownloadPathKey] options:0]];
    NSPredicate *filterPredicate = [NSPredicate predicateWithFormat:@"SELF like %@", filesToMatch];
    NSArray *matchingFiles = [basePathContent filteredArrayUsingPredicate:filterPredicate];
    
    NSMutableArray *filesDataArr = [NSMutableArray array];
    for (NSString *matchingFile in matchingFiles) {
        NSData *fileData = [NSData dataWithContentsOfFile:[basePath stringByAppendingPathComponent:matchingFile]];
        
        [filesDataArr addObject:fileData];
    }
    
    NSData *filesDataArrData = [NSKeyedArchiver archivedDataWithRootObject:filesDataArr];
    
    NSString *ret = [filesDataArrData base64EncodedStringWithOptions:0];
    
    NSString *debugInfo = [NSString stringWithFormat:@"Found %ld files matching download request@", (unsigned long)matchingFiles.count];
    return @{ SBTUITunnelResponseResultKey: ret ?: @"", SBTUITunnelResponseDebugKey: debugInfo };
}

#pragma mark - Other Commands

- (NSDictionary *)commandSetUIAnimations:(GCDWebServerRequest *)tunnelRequest
{
    BOOL enableAnimations = [tunnelRequest.parameters[SBTUITunnelObjectKey] boolValue];
    
    [UIView setAnimationsEnabled:enableAnimations];
    
    return @{ SBTUITunnelResponseResultKey: @"YES" };
}

- (NSDictionary *)commandSetUIAnimationSpeed:(GCDWebServerRequest *)tunnelRequest
{
    NSAssert(![NSThread isMainThread], @"Shouldn't be on main thread");
    
    NSInteger animationSpeed = [tunnelRequest.parameters[SBTUITunnelObjectKey] integerValue];
    dispatch_sync(dispatch_get_main_queue(), ^() {
        // Replacing [UIView setAnimationsEnabled:] as per
        // https://pspdfkit.com/blog/2016/running-ui-tests-with-ludicrous-speed/
        UIApplication.sharedApplication.keyWindow.layer.speed = animationSpeed;
    });
    
    NSString *debugInfo = [NSString stringWithFormat:@"Setting animationSpeed to %ld", (long)animationSpeed];
    return @{ SBTUITunnelResponseResultKey: @"YES", SBTUITunnelResponseDebugKey: debugInfo };
}

- (NSDictionary *)commandShutDown:(GCDWebServerRequest *)tunnelRequest
{
    [self.server stop];
    
    return @{ SBTUITunnelResponseResultKey: @"YES" };
}

- (NSDictionary *)commandStartupCompleted:(GCDWebServerRequest *)tunnelRequest
{
    [self.startupCommandsCompletedLock lock];
    self.startupCommandsCompleted = YES;
    [self.startupCommandsCompletedLock unlock];
    
    return @{ SBTUITunnelResponseResultKey: @"YES" };
}

#pragma mark - Custom Commands

+ (NSMutableDictionary *)customCommands
{
    static NSMutableDictionary *customCommandsDict = nil;
    
    if (customCommandsDict == nil) {
        customCommandsDict = [NSMutableDictionary dictionary];
    }
    
    return customCommandsDict;
}

+ (void)registerCustomCommandNamed:(NSString *)commandName block:(NSObject *(^)(NSObject *object))block
{
    if ([self respondsToSelector:NSSelectorFromString([commandName stringByAppendingString:@":"])]) {
        NSAssert(NO, @"Command name already taken");
    }
    if ([[self customCommands] objectForKey:commandName]) {
        NSAssert(NO, @"Custom command already registered, did you forgot to unregister it?");
    }
    
    [[self customCommands] setObject:block forKey:commandName];
}

+ (void)unregisterCommandNamed:(NSString *)commandName
{
    [[self customCommands] removeObjectForKey:commandName];
}

#pragma mark - Helper Methods

- (void)processLaunchOptionsIfNeeded
{
    if ([[NSProcessInfo processInfo].arguments containsObject:SBTUITunneledApplicationLaunchOptionResetFilesystem]) {
        deleteAppData();
        [self commandNSUserDefaultsReset:nil];
    }
    if ([[NSProcessInfo processInfo].arguments containsObject:SBTUITunneledApplicationLaunchOptionDisableUITextFieldAutocomplete]) {
        [UITextField disableAutocompleteOnce];
    }
}

- (void)processStartupCommandsIfNeeded
{
    NSLog(@"[UITestTunnelServer] Processing startup commands");
    
    BOOL localStartupCommandsCompleted = NO;
    do {
        [[NSRunLoop mainRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.1]];
        [self.startupCommandsCompletedLock lock];
        localStartupCommandsCompleted = _startupCommandsCompleted;
        [self.startupCommandsCompletedLock unlock];
    } while (!localStartupCommandsCompleted);
    
    NSLog(@"[UITestTunnelServer] Startup commands completed");
}

- (NSString *)identifierForStubRequest:(GCDWebServerRequest *)tunnelRequest
{
    NSArray<NSString *> *components = @[tunnelRequest.parameters[SBTUITunnelStubQueryRuleKey]];
    NSError *error = nil;
    NSData *jsonData = [NSJSONSerialization dataWithJSONObject:components options:NSJSONWritingPrettyPrinted error:&error];
    
    if (!jsonData || error) {
        NSLog(@"[UITestTunnelServer] Failed to create identifierForStubRequest");
        return nil;
    }
    
    return [@"stub-" stringByAppendingString:[jsonData SHA1]];
}

- (SBTProxyStubResponse *)responseForStubRequest:(GCDWebServerRequest *)tunnelRequest
{
    NSData *responseArchivedData = [[NSData alloc] initWithBase64EncodedString:tunnelRequest.parameters[SBTUITunnelStubQueryReturnDataKey] options:0];
    
    NSData *responseData = nil;
    
    id responseObject = [NSKeyedUnarchiver unarchiveObjectWithData:responseArchivedData];
    if ([responseObject isKindOfClass:[NSDictionary class]] || [responseObject isKindOfClass:[NSArray class]]) {
        NSError *error = nil;
        responseData = [NSJSONSerialization dataWithJSONObject:responseObject options:NSJSONWritingPrettyPrinted error:&error];
        if (!responseData || error) {
            NSLog(@"[UITestTunnelServer] serialize response data");
            return nil;
        }
    } else if ([responseObject isKindOfClass:[NSData class]]) {
        responseData = responseObject;
    } else {
        NSLog(@"[UITestTunnelServer] invalid serialized object of class %@", NSStringFromClass([responseObject class]));
        return nil;
    }
    
    NSUInteger responseStatusCode = [tunnelRequest.parameters[SBTUITunnelStubQueryReturnCodeKey] intValue];
    NSString *mimeType = tunnelRequest.parameters[SBTUITunnelStubQueryMimeTypeKey];
    NSUInteger contentLength = responseData.length;
    NSTimeInterval responseTime = [tunnelRequest.parameters[SBTUITunnelStubQueryResponseTimeKey] doubleValue];
    
    NSMutableDictionary<NSString *, NSString *> *headers = [NSMutableDictionary dictionaryWithDictionary:@{ @"Content-Type": mimeType,
                                                                                                            @"Content-Length": @(contentLength).stringValue }];
    
    NSString *serializedResponseHeaders = tunnelRequest.parameters[SBTUITunnelStubQueryReturnHeadersKey];
    NSData *serializedResponseHeadersData = [serializedResponseHeaders dataUsingEncoding:NSUTF8StringEncoding];
    if (serializedResponseHeadersData) {
        NSDictionary *responseHeaders = [NSJSONSerialization JSONObjectWithData:serializedResponseHeadersData options:0 error:NULL];
        if ([responseHeaders isKindOfClass:[NSDictionary class]]) {
            [headers addEntriesFromDictionary:responseHeaders];
        }
    }
    
    SBTProxyStubResponse *response = [SBTProxyStubResponse responseWithData:responseData headers:headers statusCode:responseStatusCode responseTime:responseTime];
    
    return response;
}

- (BOOL)validStubRequest:(GCDWebServerRequest *)tunnelRequest
{
    if (!tunnelRequest.parameters[SBTUITunnelStubQueryReturnCodeKey] ||
        !tunnelRequest.parameters[SBTUITunnelStubQueryMimeTypeKey] ||
        ![[NSData alloc] initWithBase64EncodedString:tunnelRequest.parameters[SBTUITunnelStubQueryRuleKey] options:0] ||
        ![[NSData alloc] initWithBase64EncodedString:tunnelRequest.parameters[SBTUITunnelStubQueryReturnDataKey] options:0]) {
        NSLog(@"[UITestTunnelServer] Invalid stubRequest received!");
        
        return NO;
    }
    
    return YES;
}

- (BOOL)validMonitorRequest:(GCDWebServerRequest *)tunnelRequest
{
    if (![[NSData alloc] initWithBase64EncodedString:tunnelRequest.parameters[SBTUITunnelProxyQueryRuleKey] options:0]) {
        NSLog(@"[UITestTunnelServer] Invalid monitorRequest received!");
        
        return NO;
    }
    
    return YES;
}

- (BOOL)validThrottleRequest:(GCDWebServerRequest *)tunnelRequest
{
    if (tunnelRequest.parameters[SBTUITunnelProxyQueryResponseTimeKey] != nil && ![[NSData alloc] initWithBase64EncodedString:tunnelRequest.parameters[SBTUITunnelProxyQueryRuleKey] options:0]) {
        NSLog(@"[UITestTunnelServer] Invalid throttleRequest received!");
        
        return NO;
    }
    
    return YES;
}


#pragma mark - Helper Functions

// https://gist.github.com/michalzelinka/67adfa0142767575194f
void deleteAppData() {
    NSFileManager *fm = [NSFileManager defaultManager];
    NSArray<NSString *> *folders = @[[NSSearchPathForDirectoriesInDomains(NSCachesDirectory, NSUserDomainMask, YES) firstObject],
                                     [NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES) firstObject],
                                     [NSSearchPathForDirectoriesInDomains(NSLibraryDirectory, NSUserDomainMask, YES) firstObject],
                                     NSTemporaryDirectory()];
    
    NSError *error = nil;
    for (NSString *folder in folders) {
        for (NSString *file in [fm contentsOfDirectoryAtPath:folder error:&error]) {
            [fm removeItemAtPath:[folder stringByAppendingPathComponent:file] error:&error];
        }
    }
}

void resetUserDefaults() {
    [[NSUserDefaults standardUserDefaults] removePersistentDomainForName:[[NSBundle mainBundle] bundleIdentifier]];
    [[NSUserDefaults standardUserDefaults] synchronize];
    
    [NSUserDefaults resetStandardUserDefaults];
}

// http://stackoverflow.com/a/26191925/574449
void (^deleteAllKeysForSecClass)(CFTypeRef) = ^(CFTypeRef secClass) {
    id dict = @{(__bridge id)kSecClass: (__bridge id)secClass};
    SecItemDelete((__bridge CFDictionaryRef) dict);
};

@end

#endif
