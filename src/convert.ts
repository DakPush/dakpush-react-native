import { DakError } from './errors';
import type {
  DakButton,
  DakInAppActionType,
  DakInAppClick,
  DakNotification,
  DakTagValue,
  DakTriggerValue,
} from './types';

/** Tag and trigger keys: 1-64 of `A-Z a-z 0-9 _ . : -` (as the server takes them). */
export const KEY_PATTERN = /^[A-Za-z0-9_.:-]{1,64}$/;

/** Bytes of UTF-8, without TextEncoder (not every JS engine has it). */
export function utf8Length(s: string): number {
  let n = 0;
  for (let i = 0; i < s.length; i++) {
    const c = s.charCodeAt(i);
    if (c < 0x80) n += 1;
    else if (c < 0x800) n += 2;
    else if (c >= 0xd800 && c <= 0xdbff && i + 1 < s.length) {
      const d = s.charCodeAt(i + 1);
      if (d >= 0xdc00 && d <= 0xdfff) {
        n += 4;
        i++;
      } else {
        n += 3;
      }
    } else n += 3;
  }
  return n;
}

/** Your own user id: 1-128 bytes of UTF-8, not an email address. */
export function checkExternalId(externalId: unknown): string {
  if (
    typeof externalId !== 'string' ||
    externalId.length === 0 ||
    utf8Length(externalId) > 128 ||
    externalId.includes('@')
  ) {
    throw new DakError(
      'use your own user id (1-128 bytes, not an email address)',
      'invalid',
      'external_id'
    );
  }
  return externalId;
}

/**
 * Tags as the native SDKs and the server take them: strings, with null for a
 * removal. Numbers and booleans become strings here, so both platforms send
 * the same text (`3`, not `3.0`).
 */
export function tagsForNative(
  tags: Record<string, DakTagValue>
): Record<string, string | null> {
  if (tags === null || typeof tags !== 'object' || Array.isArray(tags)) {
    throw new DakError('tags must be an object', 'invalid', 'tags');
  }
  const out: Record<string, string | null> = {};
  for (const key of Object.keys(tags)) {
    if (!KEY_PATTERN.test(key)) {
      throw new DakError(
        `tag key ${key} must be 1-64 of A-Z a-z 0-9 _ . : -`,
        'invalid',
        'tags'
      );
    }
    const v = tags[key];
    let s: string | null;
    if (v === null || v === undefined) s = null;
    else if (typeof v === 'string') s = v.length === 0 ? null : v;
    else if (typeof v === 'boolean') s = v ? 'true' : 'false';
    else if (typeof v === 'number' && Number.isFinite(v)) s = String(v);
    else {
      throw new DakError(
        `tag ${key}: values must be strings, numbers or booleans`,
        'invalid',
        'tags'
      );
    }
    if (s !== null && utf8Length(s) > 255) {
      throw new DakError(
        `tag ${key}: at most 255 bytes of UTF-8`,
        'invalid',
        'tags'
      );
    }
    out[key] = s;
  }
  return out;
}

/** Triggers for in-app messages: strings, finite numbers or booleans. */
export function triggersForNative(
  triggers: Record<string, DakTriggerValue>
): Record<string, DakTriggerValue> {
  if (
    triggers === null ||
    typeof triggers !== 'object' ||
    Array.isArray(triggers)
  ) {
    throw new DakError('triggers must be an object', 'invalid', 'triggers');
  }
  const out: Record<string, DakTriggerValue> = {};
  for (const key of Object.keys(triggers)) {
    checkTriggerKey(key);
    const v = triggers[key];
    if (
      typeof v !== 'string' &&
      typeof v !== 'boolean' &&
      !(typeof v === 'number' && Number.isFinite(v))
    ) {
      throw new DakError(
        `trigger ${key}: values must be strings, numbers or booleans`,
        'invalid',
        'triggers'
      );
    }
    out[key] = v;
  }
  return out;
}

export function checkTriggerKey(key: unknown): string {
  if (typeof key !== 'string' || !KEY_PATTERN.test(key)) {
    throw new DakError(
      `trigger key ${String(key)} must be 1-64 of A-Z a-z 0-9 _ . : -`,
      'invalid',
      'triggers'
    );
  }
  return key;
}

function str(v: unknown): string | null {
  return typeof v === 'string' ? v : null;
}

function strings(v: unknown): Record<string, string> {
  const out: Record<string, string> = {};
  if (v && typeof v === 'object' && !Array.isArray(v)) {
    for (const [k, x] of Object.entries(v as Record<string, unknown>)) {
      if (typeof x === 'string') out[k] = x;
      else if (typeof x === 'number' || typeof x === 'boolean')
        out[k] = String(x);
    }
  }
  return out;
}

/** A notification from the native side, with every field there. */
export function toNotification(m: unknown): DakNotification {
  const o = (m ?? {}) as Record<string, unknown>;
  const buttons: DakButton[] = Array.isArray(o.buttons)
    ? (o.buttons as unknown[]).flatMap((b) => {
        const x = (b ?? {}) as Record<string, unknown>;
        const id = str(x.id);
        const text = str(x.text);
        return id !== null && text !== null
          ? [{ id, text, url: str(x.url) }]
          : [];
      })
    : [];
  const title = str(o.title);
  const body = str(o.body);
  return {
    id: str(o.id),
    title,
    body,
    url: str(o.url),
    imageUrl: str(o.imageUrl),
    data: strings(o.data),
    buttons,
    actionId: str(o.actionId),
    raw: strings(o.raw),
    isSilent: title === null && body === null,
  };
}

const ACTION_TYPES: readonly DakInAppActionType[] = [
  'deep_link',
  'url',
  'tags',
  'dismiss',
  'custom',
];

/** An in-app click from the native side. */
export function toInAppClick(m: unknown): DakInAppClick {
  const o = (m ?? {}) as Record<string, unknown>;
  const type = str(o.actionType);
  return {
    messageId: str(o.messageId) ?? '',
    buttonId: str(o.buttonId),
    actionType: ACTION_TYPES.includes(type as DakInAppActionType)
      ? (type as DakInAppActionType)
      : 'custom',
    url: str(o.url),
    tags: strings(o.tags),
  };
}
