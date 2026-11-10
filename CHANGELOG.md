# Changelog

## 0.1.0 - unreleased

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
