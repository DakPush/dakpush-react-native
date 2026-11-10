#import <RNDakPushSpec/RNDakPushSpec.h>
#import <React/RCTEventEmitter.h>

/// The TurboModule `DakPush`. Each call goes to the DakPush iOS SDK through
/// DakPushRN (Swift); events come from DakPushRN too.
@interface RNDakPush : RCTEventEmitter <NativeDakPushSpec>

@end
