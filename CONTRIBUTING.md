# Contributing

## Layout

| | |
|---|---|
| `src/` | The TypeScript API (`Dak`), the TurboModule spec (`NativeDakPush.ts`) and Jest tests |
| `android/` | Kotlin: the TurboModule, a content provider that starts the SDK when the process starts, and the bridge that keeps events until JS listens |
| `ios/` | Objective-C++ TurboModule (`RNDakPush.mm`), the launch hook and app delegate proxy (`RNDakPushLaunch.m`), the Swift bridge (`DakPushRN.swift`) |
| `ios/vendor/` | The DakPush iOS SDK's sources at a release tag; never edit by hand |
| `plugin/` | The Expo config plugin (compiled to `plugin/build`) |
| `example/` | An Expo app (prebuild) that uses the package from this folder |

The bridge only passes calls and events on: anything that changes how pushes,
receipts or in-app messages behave belongs in the native SDKs.

## Setup

Node.js 22.13+ or 24.3+ and Yarn through the committed release (`.yarnrc.yml`):

```bash
yarn            # installs the package and the example (workspaces)
yarn typecheck
yarn lint
yarn test
yarn prepare    # lib/ and plugin/build
```

## The example against a local server

Run a throwaway `dak serve` (see the server's README): its own database, an
app with `dak app create`, identity verification off for quick tests
(`dak app set <id> --identity-verification false`), and a REST key for
in-app messages. Then:

```bash
export DAKPUSH_APP_ID=<app id> DAKPUSH_BASE_URL=http://localhost:8091
yarn build:plugin
cd example
npx expo prebuild --clean
npx expo start                        # Metro, in its own terminal
```

- iOS simulator: `npx expo run:ios`, or build `ios/DakPushRN.xcworkspace`.
  Apple-silicon simulators get a real APNs token; "Allow (provisional)" asks
  nothing. `xcrun simctl push <device> <bundle id> push.apns` with a payload
  that has `_dak_id` reaches `onForeground` while the app is open.
- Android emulator: `adb reverse tcp:8091 tcp:8091` so `localhost` reaches the
  Mac. For a real FCM token, put a `google-services.json` for the app's
  package in `example/` (git-ignored) and set `DAKPUSH_ANDROID_PACKAGE`.
  Grant the notification permission without the dialog:
  `adb shell pm grant <package> android.permission.POST_NOTIFICATIONS`.

## Updating a native SDK

- Android: the version in `android/build.gradle` (`dakPushAndroidVersion`).
- iOS: `scripts/vendor-ios.sh <tag>` copies the release into `ios/vendor`
  (set `DAKPUSH_IOS_SRC` to use a local clone). CI checks the copy with
  `scripts/vendor-ios.sh --check`.

Then update the versions in the README and the CHANGELOG.

## Commits

Small commits with a sentence that says what changed for users. Run lint,
types and tests before pushing.
