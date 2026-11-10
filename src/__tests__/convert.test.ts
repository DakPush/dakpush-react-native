import {
  checkExternalId,
  tagsForNative,
  toInAppClick,
  toNotification,
  triggersForNative,
  utf8Length,
} from '../convert';
import { DakError, toDakError } from '../errors';

describe('utf8Length', () => {
  it('counts bytes like UTF-8', () => {
    expect(utf8Length('abc')).toBe(3);
    expect(utf8Length('ঢাকা')).toBe(12); // Bangla: 3 bytes each
    expect(utf8Length('é')).toBe(2);
    expect(utf8Length('😀')).toBe(4); // a surrogate pair
    expect(utf8Length('\ud83d')).toBe(3); // a lone surrogate
  });
});

describe('checkExternalId', () => {
  it('takes 1-128 bytes without @', () => {
    expect(checkExternalId('user-42')).toBe('user-42');
    expect(checkExternalId('x'.repeat(128))).toHaveLength(128);
  });

  it.each([[''], ['a@b.com'], ['x'.repeat(129)], ['ঢ'.repeat(43)], [42]])(
    'refuses %p',
    (id) => {
      try {
        checkExternalId(id);
        throw new Error('no error');
      } catch (e) {
        expect(e).toBeInstanceOf(DakError);
        expect((e as DakError).code).toBe('invalid');
        expect((e as DakError).field).toBe('external_id');
      }
    }
  );
});

describe('tagsForNative', () => {
  it('sends text, the same on both platforms', () => {
    expect(
      tagsForNative({
        level: 3,
        score: 1.5,
        pro: true,
        trial: false,
        city: 'ঢাকা',
        gone: null,
        unset: undefined,
        empty: '',
      })
    ).toEqual({
      level: '3',
      score: '1.5',
      pro: 'true',
      trial: 'false',
      city: 'ঢাকা',
      gone: null,
      unset: null,
      empty: null,
    });
  });

  it.each([
    [{ 'bad key': 'x' }],
    [{ ['k'.repeat(65)]: 'x' }],
    [{ ok: { nested: 1 } }],
    [{ ok: [1] }],
    [{ ok: NaN }],
    [{ ok: Infinity }],
    [{ ok: 'x'.repeat(256) }],
    [{ ok: 'ঢ'.repeat(86) }],
  ])('refuses %p', (tags) => {
    expect(() => tagsForNative(tags as never)).toThrow(DakError);
  });

  it('takes keys with . : - _', () => {
    expect(tagsForNative({ 'a.b:c-d_e': 'x' })).toEqual({ 'a.b:c-d_e': 'x' });
  });
});

describe('triggersForNative', () => {
  it('keeps strings, numbers and booleans as they are', () => {
    expect(
      triggersForNative({ screen: 'home', lessons: 3, pro: true })
    ).toEqual({ screen: 'home', lessons: 3, pro: true });
  });

  it.each([[{ x: null }], [{ x: {} }], [{ x: NaN }], [{ 'a b': 1 }]])(
    'refuses %p',
    (t) => {
      expect(() => triggersForNative(t as never)).toThrow(DakError);
    }
  );
});

describe('toNotification', () => {
  it('fills every field from the native map', () => {
    const n = toNotification({
      id: 'm1',
      title: 'Hi',
      body: 'There',
      url: 'app://x',
      imageUrl: null,
      data: { a: '1', n: 2 },
      buttons: [
        { id: 'yes', text: 'Yes', url: 'app://yes' },
        { id: 'no', text: 'No', url: null },
        { id: 'broken' },
      ],
      actionId: 'yes',
      raw: { _dak_id: 'm1', a: '1' },
    });
    expect(n).toEqual({
      id: 'm1',
      title: 'Hi',
      body: 'There',
      url: 'app://x',
      imageUrl: null,
      data: { a: '1', n: '2' },
      buttons: [
        { id: 'yes', text: 'Yes', url: 'app://yes' },
        { id: 'no', text: 'No', url: null },
      ],
      actionId: 'yes',
      raw: { _dak_id: 'm1', a: '1' },
      isSilent: false,
    });
  });

  it('marks a push without title and body silent', () => {
    expect(toNotification({ data: {} }).isSilent).toBe(true);
    expect(toNotification(null).id).toBeNull();
  });
});

describe('toInAppClick', () => {
  it('reads the click', () => {
    expect(
      toInAppClick({
        messageId: 'm',
        buttonId: 'b',
        actionType: 'deep_link',
        url: 'app://x',
        tags: { level: 'b2' },
      })
    ).toEqual({
      messageId: 'm',
      buttonId: 'b',
      actionType: 'deep_link',
      url: 'app://x',
      tags: { level: 'b2' },
    });
  });

  it('treats an unknown action as custom', () => {
    expect(
      toInAppClick({ messageId: 'm', actionType: 'new_kind' }).actionType
    ).toBe('custom');
  });
});

describe('toDakError', () => {
  it('reads the code, field and status from a native rejection', () => {
    const e = toDakError({
      message: 'identity verification failed',
      code: 'identity_failed',
      userInfo: { code: 'identity_failed', field: 'external_id', status: 403 },
    });
    expect(e).toBeInstanceOf(DakError);
    expect(e.message).toBe('identity verification failed');
    expect(e.code).toBe('identity_failed');
    expect(e.field).toBe('external_id');
    expect(e.status).toBe(403);
  });

  it('reads an error event', () => {
    const e = toDakError({
      message: 'bad tag',
      code: 'invalid',
      field: 'tags',
      status: null,
    });
    expect([e.code, e.field, e.status]).toEqual(['invalid', 'tags', null]);
  });

  it('keeps a DakError and names anything else unknown', () => {
    const d = new DakError('x', 'invalid');
    expect(toDakError(d)).toBe(d);
    const u = toDakError(new Error('boom'));
    expect([u.message, u.code]).toEqual(['boom', 'unknown']);
  });
});
