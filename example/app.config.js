// The example app. Local values come from the environment, so nothing
// private is committed:
//
//   DAKPUSH_APP_ID        App ID from the dashboard (or `dak app create`)
//   DAKPUSH_BASE_URL      your server; http://localhost:<port> for a local
//                         `dak serve` (Android: adb reverse tcp:<port> tcp:<port>)
//   DAKPUSH_ANDROID_PACKAGE / DAKPUSH_IOS_BUNDLE_ID   to test with your own
//                         Firebase / APNs setup
//
// A google-services.json next to this file (git-ignored) gives Android a
// real FCM token.
const fs = require('fs');
const path = require('path');

const appId =
  process.env.DAKPUSH_APP_ID || '00000000-0000-0000-0000-000000000000';
const baseUrl = process.env.DAKPUSH_BASE_URL || 'https://push.example.com';
const androidPackage =
  process.env.DAKPUSH_ANDROID_PACKAGE || 'io.github.hridoyrocks.dak.rnexample';
const bundleId =
  process.env.DAKPUSH_IOS_BUNDLE_ID ||
  'io.github.hridoyrocks.dakpush.rnexample';
const googleServices = path.join(__dirname, 'google-services.json');

module.exports = () => ({
  name: 'DakPush RN',
  slug: 'dakpush-react-native-example',
  version: '1.0.0',
  orientation: 'portrait',
  icon: './assets/icon.png',
  userInterfaceStyle: 'automatic',
  scheme: 'dakexample',
  ios: {
    supportsTablet: true,
    bundleIdentifier: bundleId,
  },
  android: {
    package: androidPackage,
    adaptiveIcon: {
      backgroundColor: '#FFFFFF',
      foregroundImage: './assets/android-icon-foreground.png',
      backgroundImage: './assets/android-icon-background.png',
      monochromeImage: './assets/android-icon-monochrome.png',
    },
    ...(fs.existsSync(googleServices)
      ? { googleServicesFile: './google-services.json' }
      : {}),
  },
  plugins: [
    [
      '../app.plugin.js',
      {
        appId,
        baseUrl,
        debugLogs: true,
        showInForeground: true,
        sessionTimeout: 30,
      },
    ],
  ],
});
