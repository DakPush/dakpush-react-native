import { NativeEventEmitter, type EmitterSubscription } from 'react-native';

import Native from './NativeDakPush';
import type { DakSubscription } from './types';

/** The native module's event names. */
export const EVENTS = {
  opened: 'DakPush.opened',
  foreground: 'DakPush.foreground',
  error: 'DakPush.error',
  deviceId: 'DakPush.deviceId',
  inAppClick: 'DakPush.inAppClick',
} as const;

/** Taps and in-app clicks kept for a listener that is not there yet. */
export const MAX_HELD = 20;

let emitter: NativeEventEmitter | null = null;

function nativeEmitter(): NativeEventEmitter | null {
  if (!Native) return null;
  // Passing the module makes Android call addListener too, which tells the
  // native side to send what it kept for this event.
  emitter ??= new NativeEventEmitter(Native as never);
  return emitter;
}

/**
 * One event type. The native side keeps events until JS first listens to the
 * type; after that, this channel keeps taps and clicks that come while no
 * listener is added (like the native SDKs: "kept for the first listener").
 */
export class Channel<T> {
  private readonly entries: Array<{ listener: (value: T) => void }> = [];
  private held: T[] = [];
  private native: EmitterSubscription | null = null;

  constructor(
    private readonly eventName: string,
    private readonly convert: (raw: unknown) => T,
    private readonly holdWhileEmpty: boolean
  ) {}

  add(listener: (value: T) => void): DakSubscription {
    if (typeof listener !== 'function') {
      throw new TypeError('listener must be a function');
    }
    const entry = { listener };
    this.entries.push(entry);
    this.connect();
    if (this.held.length > 0) {
      const held = this.held;
      this.held = [];
      // After the caller's own setup, like the native SDKs (main thread, later).
      Promise.resolve().then(() => {
        for (const v of held) {
          if (this.entries.includes(entry)) call(listener, v);
          else this.keep(v);
        }
      });
    }
    let removed = false;
    return {
      remove: () => {
        if (removed) return;
        removed = true;
        const i = this.entries.indexOf(entry);
        if (i >= 0) this.entries.splice(i, 1);
      },
    };
  }

  /** For tests and the deviceId channel: hand a value to the listeners. */
  dispatch(value: T): void {
    if (this.entries.length === 0) {
      this.keep(value);
      return;
    }
    for (const e of [...this.entries]) call(e.listener, value);
  }

  get listenerCount(): number {
    return this.entries.length;
  }

  private keep(value: T): void {
    if (!this.holdWhileEmpty) return;
    this.held.push(value);
    if (this.held.length > MAX_HELD) this.held.shift();
  }

  private connect(): void {
    if (this.native) return;
    const e = nativeEmitter();
    if (!e) return;
    this.native = e.addListener(this.eventName, (raw: unknown) =>
      this.dispatch(this.convert(raw))
    );
  }
}

function call<T>(listener: (value: T) => void, value: T): void {
  try {
    listener(value);
  } catch (e) {
    // One listener's mistake must not keep the others from the event.
    console.error('dakpush: a listener threw', e);
  }
}
