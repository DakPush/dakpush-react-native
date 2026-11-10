# Changelog

## 0.1.1 - unreleased

- Expo plugin: loads `expo/config-plugins` (from the app's `expo`, a peer
  dependency), as Expo recommends, instead of `@expo/config-plugins`, which is
  not a dependency of this package. 0.1.0 works with npm, Yarn and pnpm's
  default settings, which make Expo's copy reachable, but would not find it
  where undeclared packages are unreachable (Yarn Plug'n'Play, pnpm with
  hoisting turned off).

## 0.1.0 - 2026-11-10

First release: the React Native SDK for DakPush, a bridge over the native
SDKs (Android 0.2.0 from JitPack, iOS 0.2.0 compiled in).

- TurboModule (New Architecture), TypeScript API with the Flutter SDK's
  names: permission, login/logout, tags, subscription, badge, device id,
  `onOpened` / `onForeground` / `onError` / `onDeviceId`, in-app triggers,
  pause, blocks (`useInAppBlock`), `onInAppClick`.
- The native SDK starts with the app's process from the app's manifest /
  Info.plist, so the tap that opened the app and in-app messages on the first
  screen work; events wait for the first JS listener.
- iOS: the app delegate passes the APNs token and silent pushes to DakPush
  without code (can be turned off).
- Expo config plugin: manifest meta-data, Info.plist, push entitlement,
  background mode, App Group, notification service extension target and pod,
  EAS extension signing.
- Reports the native SDK's `sdk_version` (`android-0.2.0`, `ios-0.2.0`).
