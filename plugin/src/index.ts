import { createRunOncePlugin, type ConfigPlugin } from '@expo/config-plugins';

import { withDakPushAndroid } from './android';
import { withDakPushIos } from './ios';
import { resolveProps, type DakPushPluginProps } from './props';

const pkg = require('../../package.json') as { name: string; version: string };

/**
 * Sets up DakPush for `expo prebuild`:
 *
 * - Android: the App ID, server and options as `<meta-data>` (the SDK starts
 *   from them when the app's process starts). The notification permission
 *   comes with the SDK's manifest.
 * - iOS: the `DakPush` dictionary in Info.plist, the push entitlement, the
 *   remote-notification background mode, the App Group, and a notification
 *   service extension (images, buttons, delivery receipts) with its pod.
 */
const withDakPush: ConfigPlugin<DakPushPluginProps> = (config, props) => {
  const p = resolveProps(props, config.ios?.bundleIdentifier);
  config = withDakPushAndroid(config, p);
  return withDakPushIos(config, p);
};

export type { DakPushPluginProps } from './props';
export default createRunOncePlugin(withDakPush, pkg.name, pkg.version);
