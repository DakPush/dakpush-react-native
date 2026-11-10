#import "RNDakPush.h"

#import "RNDakPushSwift.h"

static NSString *const RNDakPushNotStarted =
    @"DakPush is not started: add the DakPush dictionary (AppId, BaseURL) to Info.plist "
    @"(the Expo plugin does this)";

@implementation RNDakPush

+ (NSString *)moduleName
{
  return @"DakPush";
}

+ (BOOL)requiresMainQueueSetup
{
  return YES;
}

- (dispatch_queue_t)methodQueue
{
  // The SDK's UI and state live on the main thread.
  return dispatch_get_main_queue();
}

- (instancetype)init
{
  if (self = [super init]) {
    __weak RNDakPush *weakSelf = self;
    dispatch_async(dispatch_get_main_queue(), ^{
      RNDakPush *me = weakSelf;
      if (me == nil) {
        return;
      }
      [DakPushRN attach];
      [DakPushRN setEmitter:me
                       emit:^(NSString *name, id body) {
                         [weakSelf sendEventWithName:name body:body];
                       }];
    });
  }
  return self;
}

- (NSArray<NSString *> *)supportedEvents
{
  return DakPushRN.events;
}

- (void)invalidate
{
  RNDakPush *me = self;
  dispatch_async(dispatch_get_main_queue(), ^{
    [DakPushRN clearEmitter:me];
    [DakPushRN endAllInAppBlocks];
  });
  [super invalidate];
}

- (std::shared_ptr<facebook::react::TurboModule>)getTurboModule:
    (const facebook::react::ObjCTurboModule::InitParams &)params
{
  return std::make_shared<facebook::react::NativeDakPushSpecJSI>(params);
}

#pragma mark - Helpers

- (BOOL)started:(RCTPromiseRejectBlock)reject
{
  if (DakPushRN.isStarted) {
    return YES;
  }
  reject(@"not_started", RNDakPushNotStarted, nil);
  return NO;
}

/// Resolves, or rejects with the DakPush error's code and its details in userInfo.
static void (^RNDakPushDone(RCTPromiseResolveBlock resolve, RCTPromiseRejectBlock reject))(NSDictionary *)
{
  return ^(NSDictionary *error) {
    if (error == nil) {
      resolve(nil);
      return;
    }
    NSString *code = [error[@"code"] isKindOfClass:NSString.class] ? error[@"code"] : @"unknown";
    NSString *message = [error[@"message"] isKindOfClass:NSString.class] ? error[@"message"] : code;
    NSMutableDictionary *info = [NSMutableDictionary dictionaryWithDictionary:@{@"code" : code}];
    if ([error[@"field"] isKindOfClass:NSString.class]) {
      info[@"field"] = error[@"field"];
    }
    if ([error[@"status"] isKindOfClass:NSNumber.class]) {
      info[@"status"] = error[@"status"];
    }
    reject(code, message, [NSError errorWithDomain:@"DakPush" code:0 userInfo:info]);
  };
}

#pragma mark - State

- (void)getState:(RCTPromiseResolveBlock)resolve reject:(RCTPromiseRejectBlock)reject
{
  resolve([DakPushRN state]);
}

- (void)getDeviceId:(RCTPromiseResolveBlock)resolve reject:(RCTPromiseRejectBlock)reject
{
  resolve(DakPushRN.deviceId ?: [NSNull null]);
}

- (void)getInitialNotification:(RCTPromiseResolveBlock)resolve reject:(RCTPromiseRejectBlock)reject
{
  resolve(DakPushRN.initialNotification ?: [NSNull null]);
}

#pragma mark - Permission

- (void)requestPermission:(BOOL)provisional
                  resolve:(RCTPromiseResolveBlock)resolve
                   reject:(RCTPromiseRejectBlock)reject
{
  [DakPushRN requestPermissionWithProvisional:provisional
                                   completion:^(BOOL allowed) {
                                     resolve(@(allowed));
                                   }];
}

- (void)hasPermission:(RCTPromiseResolveBlock)resolve reject:(RCTPromiseRejectBlock)reject
{
  [DakPushRN hasPermissionWithCompletion:^(BOOL allowed) {
    resolve(@(allowed));
  }];
}

- (void)openNotificationSettings
{
  [DakPushRN openNotificationSettings];
}

#pragma mark - User, tags, subscription

- (void)login:(NSString *)externalId
     authHash:(NSString *_Nullable)authHash
      resolve:(RCTPromiseResolveBlock)resolve
       reject:(RCTPromiseRejectBlock)reject
{
  if (![self started:reject]) {
    return;
  }
  [DakPushRN login:externalId authHash:authHash completion:RNDakPushDone(resolve, reject)];
}

- (void)logout:(RCTPromiseResolveBlock)resolve reject:(RCTPromiseRejectBlock)reject
{
  if (![self started:reject]) {
    return;
  }
  [DakPushRN logoutWithCompletion:RNDakPushDone(resolve, reject)];
}

- (void)setTags:(NSDictionary *)tags resolve:(RCTPromiseResolveBlock)resolve reject:(RCTPromiseRejectBlock)reject
{
  if (![self started:reject]) {
    return;
  }
  [DakPushRN setTags:tags completion:RNDakPushDone(resolve, reject)];
}

- (void)setSubscribed:(BOOL)subscribed
              resolve:(RCTPromiseResolveBlock)resolve
               reject:(RCTPromiseRejectBlock)reject
{
  if (![self started:reject]) {
    return;
  }
  [DakPushRN setSubscribed:subscribed completion:RNDakPushDone(resolve, reject)];
}

- (void)setBadge:(double)count resolve:(RCTPromiseResolveBlock)resolve reject:(RCTPromiseRejectBlock)reject
{
  [DakPushRN setBadge:(NSInteger)MAX(0, count)];
  resolve(nil);
}

- (void)flush:(RCTPromiseResolveBlock)resolve reject:(RCTPromiseRejectBlock)reject
{
  if (![self started:reject]) {
    return;
  }
  [DakPushRN flushWithCompletion:RNDakPushDone(resolve, reject)];
}

- (void)showNotification:(NSString *)id resolve:(RCTPromiseResolveBlock)resolve reject:(RCTPromiseRejectBlock)reject
{
  // iOS shows messages that arrive while the app is open by the
  // ShowInForeground setting; there is nothing to show afterwards.
  resolve(@NO);
}

#pragma mark - In-app messages

- (void)addTriggers:(NSDictionary *)triggers
{
  [DakPushRN addTriggers:triggers];
}

- (void)removeTriggers:(NSArray *)keys
{
  NSMutableArray<NSString *> *strings = [NSMutableArray arrayWithCapacity:keys.count];
  for (id key in keys) {
    if ([key isKindOfClass:NSString.class]) {
      [strings addObject:key];
    }
  }
  [DakPushRN removeTriggers:strings];
}

- (void)clearTriggers
{
  [DakPushRN clearTriggers];
}

- (void)pauseInApp:(BOOL)paused
{
  [DakPushRN pauseInApp:paused];
}

- (void)isInAppPaused:(RCTPromiseResolveBlock)resolve reject:(RCTPromiseRejectBlock)reject
{
  resolve(@(!DakPushRN.isStarted || DakPushRN.isInAppPaused));
}

- (void)blockInApp:(double)id
{
  if (DakPushRN.isStarted) {
    [DakPushRN blockInApp:(NSInteger)id];
  }
}

- (void)endInAppBlock:(double)id
{
  [DakPushRN endInAppBlock:(NSInteger)id];
}

- (void)refreshInApp:(RCTPromiseResolveBlock)resolve reject:(RCTPromiseRejectBlock)reject
{
  [DakPushRN refreshInAppWithCompletion:^{
    resolve(nil);
  }];
}

#pragma mark - Events

- (void)addListener:(NSString *)eventName
{
  [super addListener:eventName];
  [DakPushRN jsListening:self event:eventName];
}

- (void)removeListeners:(double)count
{
  [super removeListeners:count];
}

@end
