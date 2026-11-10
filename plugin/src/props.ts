/** The Expo plugin's options: `["dakpush-react-native", { appId, baseUrl, ... }]`. */
export interface DakPushPluginProps {
  /** The App ID from the DakPush dashboard. */
  appId: string;
  /**
   * Your DakPush server's public URL, without `/v1`. It must be https; plain
   * http works only for `localhost` (and `10.0.2.2`, `127.0.0.1`) while
   * testing.
   */
  baseUrl: string;
  /**
   * Show messages that arrive while the app is open the way they show in the
   * background (the `onForeground` listeners get them either way). Off by
   * default.
   */
  showInForeground?: boolean;
  /** Send the phone's UTC offset, for pushes at the user's local time. */
  shareTimezoneOffset?: boolean;
  /** Log what the SDK does (Logcat tag "Dak", Console.app subsystem "dakpush"). */
  debugLogs?: boolean;
  /** Show in-app messages (default true). */
  inAppMessages?: boolean;
  /** In-app sessions: back from the background after this many seconds starts a new one (default 300). */
  sessionTimeout?: number;
  /** In-app `url` actions open only these schemes (default `["https", "http"]`). */
  inAppUrlSchemes?: string[];
  android?: {
    /** Use Firebase Installation IDs when the app turned them on (default true). */
    useFid?: boolean;
    /** A tap on a notification the SDK shows opens the app (default true). */
    openAppOnTap?: boolean;
  };
  ios?: {
    /**
     * The APNs environment in the app's entitlements: `development` for
     * debug builds, `production` for TestFlight and the App Store (EAS sets
     * it for store builds when it signs). Default `development`.
     */
    mode?: 'development' | 'production';
    /**
     * The App Group the app shares with the notification service extension.
     * Default `group.<bundle id>.dakpush`; false for none (then no extension
     * is added).
     */
    appGroup?: string | false;
    /**
     * Add the notification service extension: images, buttons and delivery
     * receipts while the app is not running. Default true.
     */
    notificationServiceExtension?: boolean;
    /** The extension's target name. Default `DakPushNotificationService`. */
    extensionTargetName?: string;
    /**
     * Pass the APNs token and silent pushes from the app delegate to DakPush
     * without code (default true). With false, the app delegate calls
     * Dak.setDeviceToken itself.
     */
    appDelegateProxy?: boolean;
  };
}

export interface ResolvedProps {
  appId: string;
  baseUrl: string;
  showInForeground: boolean;
  shareTimezoneOffset: boolean;
  debugLogs: boolean;
  inAppMessages: boolean;
  sessionTimeout: number;
  inAppUrlSchemes: string[];
  android: { useFid: boolean; openAppOnTap: boolean };
  ios: {
    mode: 'development' | 'production';
    appGroup: string | null;
    extension: boolean;
    extensionTargetName: string;
    appDelegateProxy: boolean;
  };
}

const LOCAL_HOSTS = new Set(['localhost', '127.0.0.1', '10.0.2.2']);

/** Checks the options and fills in the defaults; throws for a mistake. */
export function resolveProps(
  props: Partial<DakPushPluginProps> | undefined,
  bundleIdentifier: string | undefined
): ResolvedProps {
  const p = props ?? {};
  const fail = (m: string): never => {
    throw new Error(`dakpush-react-native: ${m}`);
  };
  if (typeof p.appId !== 'string' || p.appId.trim() === '') {
    fail('set appId to the App ID from the DakPush dashboard');
  }
  if (typeof p.baseUrl !== 'string' || p.baseUrl.trim() === '') {
    fail('set baseUrl to your DakPush server, like https://push.example.com');
  }
  const baseUrl = (p.baseUrl as string).trim().replace(/\/+$/, '');
  let url: URL | null = null;
  try {
    url = new URL(baseUrl);
  } catch {
    fail(`baseUrl ${baseUrl} is not a URL`);
  }
  const u = url as URL;
  if (
    u.protocol !== 'https:' &&
    !(u.protocol === 'http:' && LOCAL_HOSTS.has(u.hostname))
  ) {
    fail(
      `baseUrl must be https (plain http only for localhost while testing), not ${baseUrl}`
    );
  }
  if (u.pathname.replace(/\/+$/, '').endsWith('/v1')) {
    fail('baseUrl is the server without /v1');
  }
  const timeout = p.sessionTimeout ?? 300;
  if (typeof timeout !== 'number' || !Number.isFinite(timeout) || timeout < 0) {
    fail('sessionTimeout is seconds, 0 or more');
  }
  const schemes = (p.inAppUrlSchemes ?? ['https', 'http']).map((s) =>
    String(s).trim().toLowerCase()
  );
  if (
    schemes.length === 0 ||
    schemes.some((s) => !/^[a-z][a-z0-9+.-]*$/.test(s))
  ) {
    fail('inAppUrlSchemes are URL schemes like "https" or "mailto"');
  }
  const ios = p.ios ?? {};
  const mode = ios.mode ?? 'development';
  if (mode !== 'development' && mode !== 'production') {
    fail('ios.mode is "development" or "production"');
  }
  let appGroup: string | null;
  if (ios.appGroup === false) appGroup = null;
  else if (typeof ios.appGroup === 'string' && ios.appGroup.trim() !== '')
    appGroup = ios.appGroup.trim();
  else appGroup = bundleIdentifier ? `group.${bundleIdentifier}.dakpush` : null;
  if (appGroup !== null && !appGroup.startsWith('group.')) {
    fail(`ios.appGroup starts with "group.", not ${appGroup}`);
  }
  const extensionTargetName =
    ios.extensionTargetName ?? 'DakPushNotificationService';
  if (!/^[A-Za-z][A-Za-z0-9_]*$/.test(extensionTargetName)) {
    fail('ios.extensionTargetName is letters, digits and _');
  }
  return {
    appId: (p.appId as string).trim(),
    baseUrl,
    showInForeground: p.showInForeground === true,
    shareTimezoneOffset: p.shareTimezoneOffset === true,
    debugLogs: p.debugLogs === true,
    inAppMessages: p.inAppMessages !== false,
    sessionTimeout: timeout,
    inAppUrlSchemes: [...new Set(schemes)],
    android: {
      useFid: p.android?.useFid !== false,
      openAppOnTap: p.android?.openAppOnTap !== false,
    },
    ios: {
      mode,
      appGroup,
      extension:
        ios.notificationServiceExtension !== false && appGroup !== null,
      extensionTargetName,
      appDelegateProxy: ios.appDelegateProxy !== false,
    },
  };
}
