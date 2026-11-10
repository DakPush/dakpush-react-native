import {
  TurboModuleRegistry,
  type CodegenTypes,
  type TurboModule,
} from 'react-native';

type UnsafeObject = CodegenTypes.UnsafeObject;

/**
 * The native module. Apps use `Dak` from the package; this spec is what
 * React Native's codegen turns into the Kotlin and Objective-C interfaces.
 *
 * Objects cross the bridge as plain maps; `src/types.ts` describes them.
 */
export interface Spec extends TurboModule {
  /** `{ started, appId, baseUrl, sdkVersion, platform }` */
  getState(): Promise<UnsafeObject>;

  getDeviceId(): Promise<string | null>;
  getInitialNotification(): Promise<UnsafeObject | null>;

  requestPermission(provisional: boolean): Promise<boolean>;
  hasPermission(): Promise<boolean>;
  openNotificationSettings(): void;

  login(externalId: string, authHash: string | null): Promise<void>;
  logout(): Promise<void>;
  /** Values are strings; null removes the tag. */
  setTags(tags: UnsafeObject): Promise<void>;
  setSubscribed(subscribed: boolean): Promise<void>;
  setBadge(count: number): Promise<void>;
  flush(): Promise<void>;
  /** Android: shows a message that came while the app was open, by its id. */
  showNotification(id: string): Promise<boolean>;

  /** Values are strings, numbers or booleans. */
  addTriggers(triggers: UnsafeObject): void;
  removeTriggers(keys: string[]): void;
  clearTriggers(): void;
  pauseInApp(paused: boolean): void;
  isInAppPaused(): Promise<boolean>;
  /** Starts a block with an id chosen by JS; `endInAppBlock` ends it. */
  blockInApp(id: number): void;
  endInAppBlock(id: number): void;
  refreshInApp(): Promise<void>;

  // NativeEventEmitter
  addListener(eventName: string): void;
  removeListeners(count: number): void;
}

/** Null when the app was built without the native code (Expo Go, web). */
export default TurboModuleRegistry.get<Spec>('DakPush');
