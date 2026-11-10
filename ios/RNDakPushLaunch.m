#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>

#import "RNDakPushSwift.h"

/**
 * Starts DakPush when the app finishes launching, with no code in the app
 * delegate:
 *
 * - The app delegate gets the APNs token, its failures and silent pushes
 *   passed on to DakPush, before (and besides) its own handling.
 * - The SDK starts from Info.plist and becomes the notification center's
 *   delegate (forwarding to the one the app set), early enough to see the
 *   tap that launched the app.
 *
 * `DakPush` → `AppDelegateProxy` = NO in Info.plist turns the first part off;
 * the app then calls Dak.setDeviceToken etc. itself (see the README).
 */
@interface RNDakPushLaunch : NSObject
@end

/// The app delegate, kept alive: UIKit holds the delegate it made at launch
/// itself, but not one set again (below).
static id RNDakPushDelegate = nil;

/// Replaces the method, or adds it to the class when the class only
/// inherits it or has none; returns the implementation to call on, or NULL
/// when there was none. [isNew] is set when the delegate did not have the
/// method at all.
static IMP RNDakPushSwap(Class cls, SEL sel, id block, const char *types, BOOL *isNew)
{
  IMP replacement = imp_implementationWithBlock(block);
  Method method = class_getInstanceMethod(cls, sel);
  if (method == NULL) {
    class_addMethod(cls, sel, replacement, types);
    *isNew = YES;
    return NULL;
  }
  IMP inherited = method_getImplementation(method);
  if (class_addMethod(cls, sel, replacement, method_getTypeEncoding(method))) {
    return inherited;
  }
  return method_setImplementation(method, replacement);
}

@implementation RNDakPushLaunch

+ (void)load
{
  [[NSNotificationCenter defaultCenter] addObserver:self
                                           selector:@selector(didFinishLaunching:)
                                               name:UIApplicationDidFinishLaunchingNotification
                                             object:nil];
}

+ (void)didFinishLaunching:(NSNotification *)notification
{
  [[NSNotificationCenter defaultCenter] removeObserver:self
                                                  name:UIApplicationDidFinishLaunchingNotification
                                                object:nil];
  if (DakPushRN.appDelegateProxyEnabled) {
    [self proxyAppDelegate];
  }
  [DakPushRN startFromInfoPlist];
}

+ (void)proxyAppDelegate
{
  static BOOL done = NO;
  if (done) {
    return;
  }
  UIApplication *app = UIApplication.sharedApplication;
  id<UIApplicationDelegate> delegate = app.delegate;
  if (delegate == nil) {
    NSLog(@"DakPush: no app delegate; pass the APNs token on with Dak.setDeviceToken");
    return;
  }
  done = YES;
  Class cls = [(NSObject *)delegate class];
  BOOL isNew = NO;

  SEL tokenSel = @selector(application:didRegisterForRemoteNotificationsWithDeviceToken:);
  __block IMP tokenNext = NULL;
  tokenNext = RNDakPushSwap(
      cls,
      tokenSel,
      ^(id me, UIApplication *application, NSData *token) {
        [DakPushRN didRegisterWithDeviceToken:token];
        if (tokenNext != NULL) {
          ((void (*)(id, SEL, UIApplication *, NSData *))tokenNext)(me, tokenSel, application, token);
        }
      },
      "v@:@@",
      &isNew);

  SEL failSel = @selector(application:didFailToRegisterForRemoteNotificationsWithError:);
  __block IMP failNext = NULL;
  failNext = RNDakPushSwap(
      cls,
      failSel,
      ^(id me, UIApplication *application, NSError *error) {
        [DakPushRN didFailToRegisterWithError:error];
        if (failNext != NULL) {
          ((void (*)(id, SEL, UIApplication *, NSError *))failNext)(me, failSel, application, error);
        }
      },
      "v@:@@",
      &isNew);

  SEL pushSel = @selector(application:didReceiveRemoteNotification:fetchCompletionHandler:);
  __block IMP pushNext = NULL;
  pushNext = RNDakPushSwap(
      cls,
      pushSel,
      ^(id me, UIApplication *application, NSDictionary *userInfo, void (^completion)(UIBackgroundFetchResult)) {
        if (pushNext == NULL) {
          if (![DakPushRN didReceiveRemoteNotification:userInfo completion:completion]) {
            completion(UIBackgroundFetchResultNoData);
          }
          return;
        }
        // Both DakPush and the app's own handling get the push; the system
        // hears back once, when both are done, with the better result.
        __block NSInteger pending = 2;
        __block UIBackgroundFetchResult best = UIBackgroundFetchResultNoData;
        void (^finish)(UIBackgroundFetchResult) = ^(UIBackgroundFetchResult result) {
          dispatch_async(dispatch_get_main_queue(), ^{
            if (pending <= 0) {
              return;
            }
            if (result == UIBackgroundFetchResultNewData ||
                (result == UIBackgroundFetchResultFailed && best == UIBackgroundFetchResultNoData)) {
              best = result;
            }
            pending -= 1;
            if (pending == 0) {
              completion(best);
            }
          });
        };
        if (![DakPushRN didReceiveRemoteNotification:userInfo completion:finish]) {
          finish(UIBackgroundFetchResultNoData);
        }
        ((void (*)(id, SEL, UIApplication *, NSDictionary *, void (^)(UIBackgroundFetchResult)))pushNext)(
            me, pushSel, application, userInfo, finish);
      },
      "v@:@@@?",
      &isNew);

  if (isNew) {
    // UIKit notes which methods the delegate has when it is set: set it
    // again, so it sees the ones added here. Only then, and with the
    // delegate kept alive (an app delegate made at launch is held by UIKit
    // only until it is replaced).
    RNDakPushDelegate = delegate;
    app.delegate = nil;
    app.delegate = delegate;
  }
}

@end
