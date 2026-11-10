import {
  AndroidConfig,
  withAndroidManifest,
  type ConfigPlugin,
} from 'expo/config-plugins';

import type { ResolvedProps } from './props';

const PREFIX = 'dakpush.';

/** The `<meta-data>` the bridge reads when the app's process starts. */
export function androidMetaData(p: ResolvedProps): Array<[string, string]> {
  return [
    ['dakpush.app_id', p.appId],
    ['dakpush.base_url', p.baseUrl],
    ['dakpush.show_in_foreground', String(p.showInForeground)],
    ['dakpush.share_timezone_offset', String(p.shareTimezoneOffset)],
    ['dakpush.debug_logs', String(p.debugLogs)],
    ['dakpush.in_app_messages', String(p.inAppMessages)],
    ['dakpush.session_timeout', String(p.sessionTimeout)],
    ['dakpush.in_app_url_schemes', p.inAppUrlSchemes.join(',')],
    ['dakpush.use_fid', String(p.android.useFid)],
    ['dakpush.open_app_on_tap', String(p.android.openAppOnTap)],
  ];
}

export const withDakPushAndroid: ConfigPlugin<ResolvedProps> = (config, p) => {
  if (!config.android?.googleServicesFile) {
    console.warn(
      'dakpush-react-native: Android pushes come through Firebase Cloud Messaging; ' +
        'set android.googleServicesFile to your google-services.json'
    );
  }
  return withAndroidManifest(config, (c) => {
    const app = AndroidConfig.Manifest.getMainApplicationOrThrow(c.modResults);
    // Settings from an earlier prebuild go first, so removed options go too.
    app['meta-data'] = (app['meta-data'] ?? []).filter(
      (m) => !m.$['android:name'].startsWith(PREFIX)
    );
    for (const [name, value] of androidMetaData(p)) {
      AndroidConfig.Manifest.addMetaDataItemToMainApplication(app, name, value);
    }
    return c;
  });
};
