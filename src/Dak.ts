import { Platform } from 'react-native';

import {
  checkExternalId,
  checkTriggerKey,
  tagsForNative,
  toInAppClick,
  toNotification,
  triggersForNative,
} from './convert';
import { DakError, toDakError } from './errors';
import { Channel, EVENTS } from './events';
import Native, { type Spec } from './NativeDakPush';
import type {
  DakInAppBlock,
  DakInAppClick,
  DakNotification,
  DakState,
  DakSubscription,
  DakTagValue,
  DakTriggerValue,
} from './types';

const MISSING =
  'dakpush-react-native: the native module is not in this build. Rebuild the app ' +
  '(npx expo prebuild, or pod install for iOS); Expo Go does not have it.';

let warnedMissing = false;

function native(): Spec {
  if (Native) return Native;
  throw new DakError(MISSING, 'unavailable');
}

/** The module, or null with one warning: for calls that return nothing. */
function nativeOrWarn(): Spec | null {
  if (Native) return Native;
  if (!warnedMissing) {
    warnedMissing = true;
    console.warn(MISSING);
  }
  return null;
}

/** For calls that resolve with nothing: Android resolves null, iOS nothing. */
function done(call: (n: Spec) => Promise<unknown>): Promise<void> {
  return run(call).then(() => undefined);
}

async function run<T>(call: (n: Spec) => Promise<T>): Promise<T> {
  let n: Spec;
  try {
    n = native();
  } catch (e) {
    throw toDakError(e);
  }
  try {
    return await call(n);
  } catch (e) {
    throw toDakError(e);
  }
}

const opened = new Channel<DakNotification>(
  EVENTS.opened,
  toNotification,
  true
);
const foreground = new Channel<DakNotification>(
  EVENTS.foreground,
  toNotification,
  false
);
const errors = new Channel<DakError>(EVENTS.error, toDakError, false);
const inAppClicks = new Channel<DakInAppClick>(
  EVENTS.inAppClick,
  toInAppClick,
  true
);
const deviceIds = new Channel<string>(
  EVENTS.deviceId,
  (raw) => (typeof raw === 'string' ? raw : String(raw)),
  false
);

let nextBlockId = 1;

/**
 * The SDK's entry point.
 *
 * The native SDK starts with the app, before your JavaScript runs, from the
 * App ID and server URL in the app's AndroidManifest.xml and Info.plist (the
 * Expo plugin writes them). So it sees the tap that opened the app, and
 * in-app messages can show on the first screen.
 *
 * ```ts
 * import { Dak } from 'dakpush-react-native';
 *
 * await Dak.requestPermission();
 * await Dak.login(userId, hashFromYourServer);
 * Dak.onOpened((n) => openRoute(n.url));
 *
 * // In-app messages
 * Dak.addTrigger('screen', 'home');
 * Dak.onInAppClick((c) => {
 *   if (c.actionType === 'deep_link') openRoute(c.url);
 * });
 * ```
 */
export class Dak {
  private constructor() {}

  /**
   * Whether the native SDK runs, with its App ID, server and version. It
   * starts with the app when the app's native settings have an App ID and a
   * server URL; `started` is false without them.
   */
  static getState(): Promise<DakState> {
    return run(async (n) => {
      const s = (await n.getState()) as Record<string, unknown>;
      return {
        started: s.started === true,
        appId: typeof s.appId === 'string' ? s.appId : null,
        baseUrl: typeof s.baseUrl === 'string' ? s.baseUrl : null,
        sdkVersion: typeof s.sdkVersion === 'string' ? s.sdkVersion : '',
        platform: Platform.OS === 'ios' ? 'ios' : 'android',
      };
    });
  }

  /**
   * Asks the user to allow notifications and resolves to whether they are
   * allowed. Android 13+ shows the system prompt (older Android allows them
   * without one). On iOS, `provisional: true` asks nothing: notifications go
   * quietly to the Notification Center, where the user keeps or turns them
   * off. After a refusal the system stops asking;
   * {@link Dak.openNotificationSettings} is left then.
   */
  static requestPermission(
    options: { provisional?: boolean } = {}
  ): Promise<boolean> {
    return run((n) => n.requestPermission(options.provisional === true));
  }

  /** Whether the user allows this app's notifications (provisional counts). */
  static hasPermission(): Promise<boolean> {
    return run((n) => n.hasPermission());
  }

  /** Opens this app's notification settings. */
  static openNotificationSettings(): void {
    nativeOrWarn()?.openNotificationSettings();
  }

  /**
   * Links this device to your user id. With identity verification on (the
   * server's default), `authHash` must come from your server:
   * hex(HMAC-SHA256(key = identity secret, message = externalId)).
   *
   * Rejects with a {@link DakError} when the server refuses (a wrong auth
   * hash); then only the user id is rolled back. Network problems never fail:
   * the change is saved and sent later.
   */
  static login(externalId: string, authHash?: string | null): Promise<void> {
    return done((n) =>
      n.login(
        checkExternalId(externalId),
        typeof authHash === 'string' && authHash.length > 0 ? authHash : null
      )
    );
  }

  /**
   * Unlinks the user from this device and removes its tags, so the next user
   * of the phone starts without them. Push permission and the subscription
   * stay.
   */
  static logout(): Promise<void> {
    return done((n) => n.logout());
  }

  /**
   * Sets tags on this device; null, undefined or '' removes a tag. Values are
   * strings, numbers or booleans, sent as strings. Keys are 1-64 of
   * `A-Z a-z 0-9 _ . : -`, values at most 255 bytes of UTF-8.
   */
  static setTags(tags: Record<string, DakTagValue>): Promise<void> {
    return done((n) => n.setTags(tagsForNative(tags)));
  }

  /** Sets one tag; see {@link Dak.setTags}. */
  static setTag(key: string, value: DakTagValue): Promise<void> {
    return Dak.setTags({ [key]: value });
  }

  /** Removes the tags with these keys. */
  static deleteTags(keys: string[]): Promise<void> {
    const tags: Record<string, null> = {};
    for (const k of keys) tags[k] = null;
    return Dak.setTags(tags);
  }

  /** Removes one tag. */
  static deleteTag(key: string): Promise<void> {
    return Dak.deleteTags([key]);
  }

  /**
   * Opts this device out of (false) or back into (true) all pushes, for a
   * switch in your app's settings. Notification permission is not changed.
   */
  static setSubscribed(subscribed: boolean): Promise<void> {
    return done((n) => n.setSubscribed(subscribed === true));
  }

  /**
   * iOS: sets the app icon's badge; badge increments from later pushes add
   * to it. Android launchers count notifications themselves; this does
   * nothing there.
   */
  static setBadge(count: number): Promise<void> {
    const c = Number.isFinite(count) ? Math.max(0, Math.floor(count)) : 0;
    return done((n) => n.setBadge(c));
  }

  /** Same as `setBadge(0)`. */
  static clearBadge(): Promise<void> {
    return Dak.setBadge(0);
  }

  /** Sends anything waiting now, for example when the network comes back. */
  static flush(): Promise<void> {
    return done((n) => n.flush());
  }

  /**
   * Android: shows a message that arrived while the app was open (from
   * {@link Dak.onForeground}) the way it would have shown in the background,
   * buttons and image included. Resolves to false when nothing was shown:
   * notifications off, no title and text, not a DakPush message, or iOS
   * (there, the `showInForeground` setting decides).
   */
  static async showNotification(
    notification: DakNotification
  ): Promise<boolean> {
    if (Platform.OS !== 'android' || !notification?.id) return false;
    return run((n) => n.showNotification(notification.id as string));
  }

  /**
   * This device's id on the DakPush server, or null before it is registered.
   * Use {@link Dak.onDeviceId} to get it when it comes.
   */
  static getDeviceId(): Promise<string | null> {
    return run((n) => n.getDeviceId());
  }

  /**
   * The notification the user tapped to open the app, if any. The first
   * {@link Dak.onOpened} listener gets it too.
   */
  static getInitialNotification(): Promise<DakNotification | null> {
    return run(async (n) => {
      const raw = await n.getInitialNotification();
      return raw == null ? null : toNotification(raw);
    });
  }

  /**
   * Calls `listener` for taps on DakPush notifications.
   * {@link DakNotification.actionId} tells which button was tapped, if one
   * was. Taps that come while no listener is added (the tap that opened the
   * app) are kept for the next one. The SDK reports the open itself.
   */
  static onOpened(listener: (n: DakNotification) => void): DakSubscription {
    return opened.add(listener);
  }

  /**
   * Calls `listener` for DakPush messages that arrive while the app is open,
   * silent ones too. With `showInForeground` off (the default) the system
   * shows nothing then; on Android, {@link Dak.showNotification} can show one.
   */
  static onForeground(listener: (n: DakNotification) => void): DakSubscription {
    return foreground.add(listener);
  }

  /**
   * Calls `listener` for changes the server refused, such as a wrong auth
   * hash or a bad tag, also from syncs that run in the background. Only the
   * refused field is rolled back.
   */
  static onError(listener: (error: DakError) => void): DakSubscription {
    return errors.add(listener);
  }

  /**
   * Calls `listener` with the device id: soon after this call when there is
   * one, then each new one (the first registration, or registering again
   * after the server forgot the device). Never the same id twice in a row.
   */
  static onDeviceId(listener: (deviceId: string) => void): DakSubscription {
    let last: string | null = null;
    let live = true;
    const deliver = (id: string) => {
      if (!live || id === last) return;
      last = id;
      listener(id);
    };
    const sub = deviceIds.add(deliver);
    const n = Native;
    if (n) {
      n.getDeviceId().then(
        (id) => {
          if (id && last === null) deliver(id);
        },
        () => {}
      );
    }
    return {
      remove: () => {
        live = false;
        sub.remove();
      },
    };
  }

  // ---- in-app messages

  /**
   * Sets a trigger that in-app messages can wait for, such as the screen the
   * user is on (`Dak.addTrigger('screen', 'checkout')`). Triggers stay on the
   * phone and are forgotten when the app's process ends.
   */
  static addTrigger(key: string, value: DakTriggerValue): void {
    Dak.addTriggers({ [key]: value });
  }

  /** Sets several triggers at once; see {@link Dak.addTrigger}. */
  static addTriggers(triggers: Record<string, DakTriggerValue>): void {
    const values = triggersForNative(triggers);
    nativeOrWarn()?.addTriggers(values);
  }

  /** Removes a trigger. */
  static removeTrigger(key: string): void {
    Dak.removeTriggers([key]);
  }

  /** Removes several triggers. */
  static removeTriggers(keys: string[]): void {
    const checked = keys.map(checkTriggerKey);
    nativeOrWarn()?.removeTriggers(checked);
  }

  /** Removes all triggers. */
  static clearTriggers(): void {
    nativeOrWarn()?.clearTriggers();
  }

  /**
   * Stops (true) or allows (false) in-app messages, for example during a
   * call or a payment. A message on screen is hidden, not dismissed, and
   * comes back when they are allowed again. For a screen that must stay
   * clear, {@link Dak.blockInApp} or {@link useInAppBlock} nest better.
   */
  static pauseInApp(paused: boolean): void {
    nativeOrWarn()?.pauseInApp(paused === true);
  }

  /**
   * Whether in-app messages are kept away now: by pauseInApp, a block, or
   * in-app messages turned off in the app's settings.
   */
  static isInAppPaused(): Promise<boolean> {
    return run((n) => n.isInAppPaused());
  }

  /**
   * Keeps in-app messages away until the returned block ends, for a screen
   * that must stay clear. Blocks nest: messages come back when the last one
   * ends. In a component, {@link useInAppBlock} does this for you.
   */
  static blockInApp(): DakInAppBlock {
    const n = nativeOrWarn();
    if (!n) return { end: () => {} };
    const id = nextBlockId++;
    n.blockInApp(id);
    let ended = false;
    return {
      end: () => {
        if (ended) return;
        ended = true;
        n.endInAppBlock(id);
      },
    };
  }

  /**
   * Calls `listener` for taps on in-app messages and their buttons, after
   * the message closed. Deep links (`deep_link`) are yours to route; web
   * pages are opened in the browser and tags set by the SDK already. Clicks
   * that come while no listener is added are kept for the next one.
   */
  static onInAppClick(
    listener: (click: DakInAppClick) => void
  ): DakSubscription {
    return inAppClicks.add(listener);
  }

  /**
   * Fetches the in-app messages again now (iOS). Android fetches them at
   * each session start; this resolves at once there.
   */
  static refreshInApp(): Promise<void> {
    return done((n) => n.refreshInApp());
  }
}

/** For tests: the channels behind the `on…` functions. */
export const _channels = { opened, foreground, errors, inAppClicks, deviceIds };
