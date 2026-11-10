# dakpush-react-native

React Native SDK for DakPush, the push notification platform. It registers
the phone with your DakPush server, links it to your user, keeps tags,
reports deliveries, opens and button taps, shows notifications with images
and buttons, and shows the in-app messages made in the DakPush dashboard.

It is a thin bridge over the native DakPush SDKs, so an app gets exactly
their behaviour:

| | Native SDK | Push delivery |
|---|---|---|
| Android | [dakpush-android](https://github.com/DakPush/dakpush-android) 0.2.0 (JitPack) | Your Firebase project (FCM) |
| iOS | [dakpush-ios](https://github.com/DakPush/dakpush-ios) 0.2.0 (compiled in, see [below](#ios-sdk-inside-the-package)) | APNs directly, no Firebase |

## Requirements

| | Minimum |
|---|---|
| React Native | 0.76 with the New Architecture (the default since 0.76, the only one from 0.82). Tested with 0.88.1 |
| Expo | SDK 52 with a development build (`expo prebuild` / EAS Build); tested with SDK 58. Expo Go does not have it |
| Android | minSdk 24, a Firebase project (`google-services.json`) |
| iOS | 15.1, the Push Notifications capability |
| Server | A DakPush app with the Firebase service account (Android) and an APNs key (iOS) |

## Install

```bash
npm install dakpush-react-native
```

(or `yarn add` / `npx expo install`). Remove other push SDKs (OneSignal, or
expo-notifications for remote pushes) so only one library handles pushes.

### Expo

Add the plugin with your App ID and server, then make a new native build:

```json
{
  "expo": {
    "android": { "googleServicesFile": "./google-services.json" },
    "ios": { "bundleIdentifier": "com.example.app" },
    "plugins": [
      ["dakpush-react-native", {
        "appId": "YOUR_APP_ID",
        "baseUrl": "https://push.example.com"
      }]
    ]
  }
}
```

```bash
npx expo prebuild
npx expo run:android   # or run:ios, or an EAS build
```

The plugin writes the settings into AndroidManifest.xml and Info.plist, and
on iOS adds the push entitlement, the `remote-notification` background mode,
an App Group, and a notification service extension (images, buttons and
delivery receipts) with its pod. EAS Build signs the extension too.

| Option | Default | |
|---|---|---|
| `appId` | required | The App ID from the DakPush dashboard |
| `baseUrl` | required | Your server, without `/v1`. https; plain http only for `localhost` while testing |
| `showInForeground` | `false` | Show pushes that arrive while the app is open, as in the background |
| `shareTimezoneOffset` | `false` | Send the phone's UTC offset, for pushes at local time and quiet hours |
| `debugLogs` | `false` | Log what the SDK does (Logcat tag `Dak`, Console.app subsystem `dakpush`) |
| `inAppMessages` | `true` | Fetch and show in-app messages |
| `sessionTimeout` | `300` | Seconds in the background that start a new in-app session |
| `inAppUrlSchemes` | `["https", "http"]` | Schemes an in-app `url` action may open |
| `android.useFid` | `true` | Firebase Installation IDs when the app turned them on |
| `android.openAppOnTap` | `true` | A tap on a notification the SDK shows opens the app |
| `ios.mode` | `"development"` | `aps-environment`; `"production"` for TestFlight and the App Store |
| `ios.appGroup` | `group.<bundle id>.dakpush` | Shared by the app and the extension; `false` for none (no extension then) |
| `ios.notificationServiceExtension` | `true` | Add the extension |
| `ios.extensionTargetName` | `DakPushNotificationService` | |
| `ios.appDelegateProxy` | `true` | Pass the APNs token and silent pushes on without code ([below](#ios-app-delegate)) |

### Bare React Native

Autolinking adds the native code. Then:

**Android.** Set up Firebase as usual (`google-services.json` and the
`com.google.gms.google-services` plugin), and add to `<application>` in
`android/app/src/main/AndroidManifest.xml`:

```xml
<meta-data android:name="dakpush.app_id" android:value="YOUR_APP_ID" />
<meta-data android:name="dakpush.base_url" android:value="https://push.example.com" />
<!-- optional, same names as the Expo options:
     dakpush.show_in_foreground, dakpush.share_timezone_offset, dakpush.debug_logs,
     dakpush.in_app_messages, dakpush.session_timeout (seconds),
     dakpush.in_app_url_schemes (comma-separated), dakpush.use_fid, dakpush.open_app_on_tap -->
```

The notification permission comes with the SDK. The SDK is on JitPack, which
React Native's Gradle plugin adds to every project (unless the app set
`react.includeJitpackRepository=false`).

**iOS.** In `ios/YourApp/Info.plist`:

```xml
<key>DakPush</key>
<dict>
  <key>AppId</key><string>YOUR_APP_ID</string>
  <key>BaseURL</key><string>https://push.example.com</string>
  <key>AppGroup</key><string>group.com.example.app.dakpush</string>
  <!-- optional: ShowInForeground, ShareTimezoneOffset, DebugLogs, InAppMessages,
       SessionTimeout (seconds), InAppUrlSchemes (array), AppDelegateProxy,
       RegisterForRemoteNotifications, InstallNotificationDelegate -->
</dict>
<key>UIBackgroundModes</key>
<array><string>remote-notification</string></array>
```

In Xcode, add the **Push Notifications** capability and an **App Group**
(the one in `AppGroup`). For images, buttons and delivery receipts while the
app is not running, add a **Notification Service Extension** target with the
same App Group (also in its Info.plist as `DakAppGroup`), make its class

```swift
import DakPushExtension

final class NotificationService: DakNotificationService {}
```

and give it the pod in `ios/Podfile`:

```ruby
target 'NotificationService' do
  pod 'DakPushExtension', :path => '../node_modules/dakpush-react-native/ios'
end
```

Then `cd ios && pod install`. The app's own target needs no Podfile lines.

### Server

In the dashboard (or with the `dak` CLI), the app needs the Firebase service
account for Android and an APNs key for iOS, with the app's bundle id and the
environment that matches `ios.mode` (sandbox for `development`).

## Use

```tsx
import { Dak, useInAppBlock } from 'dakpush-react-native';

// Ask for permission (Android 13+ prompt; on iOS `provisional` asks nothing
// and delivers quietly to the Notification Center).
const allowed = await Dak.requestPermission();

// Link the phone to your user. With identity verification (the server's
// default) the hash comes from your backend:
// hex(HMAC-SHA256(key = identity secret, message = userId)).
await Dak.login(userId, authHash);
await Dak.logout();

// Tags for targeting; null removes one.
await Dak.setTags({ plan: 'pro', lessons: 3, verified: true });
await Dak.deleteTag('plan');

// Taps on notifications, including the one that opened the app.
const sub = Dak.onOpened((n) => {
  navigate(n.url); // n.actionId: which button, if one
});
sub.remove();

// Pushes while the app is open (shown or not by `showInForeground`).
Dak.onForeground((n) => console.log(n.title));

// Changes the server refused (a wrong auth hash, a bad tag).
Dak.onError((e) => console.warn(e.code, e.message));

// In-app messages
Dak.addTrigger('screen', 'checkout');
Dak.onInAppClick((c) => {
  if (c.actionType === 'deep_link') navigate(c.url);
});

function CallScreen() {
  useInAppBlock(); // no in-app messages while this screen is up
  return <Call />;
}
```

All calls:

| | |
|---|---|
| `requestPermission({ provisional? })`, `hasPermission()`, `openNotificationSettings()` | Notification permission |
| `login(userId, authHash?)`, `logout()` | Your user on this phone |
| `setTags(tags)`, `setTag(k, v)`, `deleteTags(keys)`, `deleteTag(k)` | Tags: keys 1-64 of `A-Z a-z 0-9 _ . : -`, values up to 255 bytes |
| `setSubscribed(bool)` | Opt this phone out of (or back into) all pushes |
| `setBadge(n)`, `clearBadge()` | iOS badge (Android launchers count notifications) |
| `getDeviceId()`, `onDeviceId(fn)` | The phone's id on the server, and when it comes |
| `onOpened(fn)`, `getInitialNotification()` | Taps |
| `onForeground(fn)`, `showNotification(n)` | Pushes while open; Android can show one later |
| `onError(fn)` | Refused changes |
| `flush()` | Send what is waiting now |
| `getState()` | Started?, App ID, server, native SDK version |
| `addTrigger(k, v)`, `addTriggers(o)`, `removeTrigger(k)`, `removeTriggers(ks)`, `clearTriggers()` | In-app triggers (kept in memory) |
| `pauseInApp(bool)`, `isInAppPaused()`, `blockInApp()`, `useInAppBlock(active?)` | Keep in-app messages away |
| `onInAppClick(fn)` | In-app taps |
| `refreshInApp()` | Fetch in-app messages again (iOS; Android fetches each session) |

Promises reject with `DakError` (`code`, `field`, `status`). Network problems
never fail a call: the change is saved and sent later. Listeners return a
subscription with `remove()`; taps and in-app clicks that come while no
listener is added are kept (20) for the next one.

## How it starts

The native SDK starts with the app's process, before your JavaScript runs,
from the settings in AndroidManifest.xml / Info.plist (a content provider on
Android, the launch notification on iOS). That is what native apps do in
`Application.onCreate` / `didFinishLaunching`, and it lets the SDK see the
tap that opened the app, show an in-app message on the first screen, and keep
events until your listeners are added. So there is no `init` call in
JavaScript; `Dak.getState()` tells whether it started.

### iOS app delegate

DakPush needs the APNs token, and silent pushes for delivery receipts. With
`AppDelegateProxy` on (the default), the package passes them from your app
delegate to DakPush at launch, then calls your own methods as before. It also
makes the SDK the notification center's delegate, forwarding to the one set
before it. To do it yourself, set `appDelegateProxy: false` (Info.plist
`AppDelegateProxy` = NO) and call, from Swift:

```swift
import DakPushReactNative

func application(_ app: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken token: Data) {
  Dak.setDeviceToken(token)
}
func application(_ app: UIApplication, didFailToRegisterForRemoteNotificationsWithError error: Error) {
  Dak.failedToRegister(with: error)
}
func application(_ app: UIApplication, didReceiveRemoteNotification userInfo: [AnyHashable: Any],
                 fetchCompletionHandler completion: @escaping (UIBackgroundFetchResult) -> Void) {
  if !Dak.didReceiveRemoteNotification(userInfo, completion: completion) { completion(.noData) }
}
```

### Android with its own FirebaseMessagingService

The SDK has its own; an app with another one extends
`io.github.hridoyrocks.dak.DakMessagingService` or passes tokens on with
`Dak.onNewToken` (see the Android SDK's README).

### iOS SDK inside the package

The iOS SDK's Swift sources (a release of dakpush-ios, in `ios/vendor`) are
compiled into this package's pod, so autolinking builds everything and the
app's Podfile needs nothing. A podspec cannot depend on a pod from git, and
CocoaPods trunk becomes read-only on 2 December 2026, so the iOS SDK is not
published there. `scripts/vendor-ios.sh` copies a release, and CI checks
that the copy is exactly that tag.

### What the server sees

The bridge reports the native SDK's version as `sdk_version`: `android-0.2.0`
and `ios-0.2.0`. Every behaviour that depends on it (buttons, in-app
rendering) is the native SDK's.

## Troubleshooting

- **`not_started`**: the app's native settings have no App ID or server.
  Run `expo prebuild` again after adding the plugin, or add the meta-data /
  Info.plist entries.
- **`unavailable`**: the build has no native code (Expo Go, web, or no
  rebuild after installing).
- **Android, never registered**: Firebase is not set up for the app's package
  (look for "Firebase is not set up" with `debugLogs`).
- **iOS, never registered**: no APNs token. On a real iPhone, the bundle id
  needs the Push Notifications capability; check `aps-environment`.
- **No images or buttons on iOS**: the App Group must be the same in the app,
  the extension's entitlements and its `DakAppGroup`.

## Example

`example/` is an Expo app (prebuild) that shows the device id, permission,
login, tags, triggers, in-app pause and block, and every event. See
[CONTRIBUTING.md](CONTRIBUTING.md) to run it against a local server.

## License

MIT
