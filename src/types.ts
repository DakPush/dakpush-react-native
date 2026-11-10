/** A notification button, as the message was sent. */
export interface DakButton {
  /** The button's id, as {@link DakNotification.actionId} reports a tap on it. */
  readonly id: string;
  /** The button's label. */
  readonly text: string;
  /** The deep link for this button, if it has its own. */
  readonly url: string | null;
}

/** A push notification as the app sees it. */
export interface DakNotification {
  /** DakPush's message id, or null for pushes not sent through DakPush. */
  readonly id: string | null;
  /** The title, or null for a silent push. */
  readonly title: string | null;
  /** The text, or null for a silent push. */
  readonly body: string | null;
  /**
   * The deep link: the tapped button's own URL if it has one, otherwise the
   * message's `url`.
   */
  readonly url: string | null;
  /** The notification's image, if it was sent with one. */
  readonly imageUrl: string | null;
  /** The message's data, without DakPush's own `_dak_` keys. */
  readonly data: Readonly<Record<string, string>>;
  /** The message's buttons. */
  readonly buttons: readonly DakButton[];
  /**
   * The id of the button the user tapped, or null for a tap on the
   * notification itself (and for messages that were not opened).
   */
  readonly actionId: string | null;
  /** The push's data as it came, with DakPush's keys. */
  readonly raw: Readonly<Record<string, string>>;
  /** A silent (data only) push has neither title nor body. */
  readonly isSilent: boolean;
}

/** What a tap on an in-app message did. */
export type DakInAppActionType =
  'deep_link' | 'url' | 'tags' | 'dismiss' | 'custom';

/** A tap on an in-app message or one of its buttons. */
export interface DakInAppClick {
  /** The message that was tapped. */
  readonly messageId: string;
  /** The button's id, or null when the message itself was tapped. */
  readonly buttonId: string | null;
  /**
   * `deep_link` is yours to route. The SDK already opened `url` actions in
   * the browser and set the tags of `tags` actions.
   */
  readonly actionType: DakInAppActionType;
  /** For `deep_link` and `url` actions. */
  readonly url: string | null;
  /** For `tags` actions: the tags that were set (an empty value removed one). */
  readonly tags: Readonly<Record<string, string>>;
}

/** Ends a listener added with one of the `Dak.on…` functions. */
export interface DakSubscription {
  remove(): void;
}

/** Keeps in-app messages away until {@link DakInAppBlock.end} is called. */
export interface DakInAppBlock {
  end(): void;
}

/** A tag value; null, undefined or '' removes the tag. */
export type DakTagValue = string | number | boolean | null | undefined;

/** A trigger value for in-app messages. */
export type DakTriggerValue = string | number | boolean;

/** What the native SDK reports about itself. */
export interface DakState {
  /**
   * True once the native SDK runs: it starts with the app from the settings
   * in the app's AndroidManifest.xml / Info.plist (the Expo plugin writes
   * them).
   */
  readonly started: boolean;
  readonly appId: string | null;
  readonly baseUrl: string | null;
  /** As the server sees it, like `android-0.2.0` or `ios-0.2.0`. */
  readonly sdkVersion: string;
  readonly platform: 'android' | 'ios';
}
