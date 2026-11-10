import { DeviceEventEmitter, Platform } from 'react-native';

jest.mock('../NativeDakPush', () => {
  const names = [
    'getState',
    'getDeviceId',
    'getInitialNotification',
    'requestPermission',
    'hasPermission',
    'openNotificationSettings',
    'login',
    'logout',
    'setTags',
    'setSubscribed',
    'setBadge',
    'flush',
    'showNotification',
    'addTriggers',
    'removeTriggers',
    'clearTriggers',
    'pauseInApp',
    'isInAppPaused',
    'blockInApp',
    'endInAppBlock',
    'refreshInApp',
    'addListener',
    'removeListeners',
  ];
  const m: Record<string, jest.Mock> = {};
  for (const n of names) m[n] = jest.fn();
  return { __esModule: true, default: m };
});

import { Dak, DakError } from '../index';
import Native, { type Spec } from '../NativeDakPush';

const mockNative = Native as unknown as { [K in keyof Spec]: jest.Mock };

const flushPromises = () => new Promise<void>((r) => setTimeout(() => r(), 0));

const notification = (id: string, extra: object = {}) => ({
  id,
  title: 'T',
  body: 'B',
  url: null,
  imageUrl: null,
  data: {},
  buttons: [],
  actionId: null,
  raw: { _dak_id: id },
  ...extra,
});

beforeEach(() => {
  jest.resetAllMocks();
  mockNative.getDeviceId.mockResolvedValue(null);
});

describe('calls', () => {
  it('logs in with the hash, or null without one', async () => {
    mockNative.login.mockResolvedValue(undefined);
    await Dak.login('user-1', 'abc');
    await Dak.login('user-2');
    await Dak.login('user-3', '');
    expect(mockNative.login.mock.calls).toEqual([
      ['user-1', 'abc'],
      ['user-2', null],
      ['user-3', null],
    ]);
  });

  it('refuses a bad user id without asking the native side', async () => {
    await expect(Dak.login('me@example.com')).rejects.toMatchObject({
      code: 'invalid',
      field: 'external_id',
    });
    expect(mockNative.login).not.toHaveBeenCalled();
  });

  it('turns a native rejection into a DakError', async () => {
    mockNative.login.mockRejectedValue(
      Object.assign(new Error('identity verification failed'), {
        code: 'identity_failed',
        userInfo: {
          code: 'identity_failed',
          field: 'external_id',
          status: 403,
        },
      })
    );
    const e = await Dak.login('user-1', 'wrong').catch((x) => x);
    expect(e).toBeInstanceOf(DakError);
    expect([e.code, e.field, e.status]).toEqual([
      'identity_failed',
      'external_id',
      403,
    ]);
  });

  it('sends tags as text and deletes with null', async () => {
    mockNative.setTags.mockResolvedValue(undefined);
    await Dak.setTags({ level: 3, pro: true, city: 'ঢাকা' });
    await Dak.setTag('score', 1.5);
    await Dak.deleteTags(['a', 'b']);
    await Dak.deleteTag('c');
    expect(mockNative.setTags.mock.calls).toEqual([
      [{ level: '3', pro: 'true', city: 'ঢাকা' }],
      [{ score: '1.5' }],
      [{ a: null, b: null }],
      [{ c: null }],
    ]);
  });

  it('asks for provisional permission only when asked', async () => {
    mockNative.requestPermission.mockResolvedValue(true);
    await expect(Dak.requestPermission()).resolves.toBe(true);
    await Dak.requestPermission({ provisional: true });
    expect(mockNative.requestPermission.mock.calls).toEqual([[false], [true]]);
  });

  it('keeps badge counts whole and not negative', async () => {
    mockNative.setBadge.mockResolvedValue(undefined);
    await Dak.setBadge(3.7);
    await Dak.setBadge(-2);
    await Dak.clearBadge();
    expect(mockNative.setBadge.mock.calls).toEqual([[3], [0], [0]]);
  });

  it('reads the state', async () => {
    mockNative.getState.mockResolvedValue({
      started: true,
      appId: 'app',
      baseUrl: 'https://push.example.com',
      sdkVersion: 'ios-0.2.0',
    });
    await expect(Dak.getState()).resolves.toEqual({
      started: true,
      appId: 'app',
      baseUrl: 'https://push.example.com',
      sdkVersion: 'ios-0.2.0',
      platform: Platform.OS,
    });
  });

  it('shows a foreground message only on Android, by its id', async () => {
    mockNative.showNotification.mockResolvedValue(true);
    const os = Platform.OS;
    try {
      Platform.OS = 'ios';
      await expect(
        Dak.showNotification(notification('m1') as never)
      ).resolves.toBe(false);
      Platform.OS = 'android';
      await expect(
        Dak.showNotification(notification('m1') as never)
      ).resolves.toBe(true);
      await expect(Dak.showNotification({ id: null } as never)).resolves.toBe(
        false
      );
    } finally {
      Platform.OS = os;
    }
    expect(mockNative.showNotification.mock.calls).toEqual([['m1']]);
  });
});

describe('in-app messages', () => {
  it('passes triggers on and refuses bad ones at once', () => {
    Dak.addTrigger('screen', 'home');
    Dak.addTriggers({ lessons: 3, pro: false });
    Dak.removeTrigger('screen');
    Dak.clearTriggers();
    expect(mockNative.addTriggers.mock.calls).toEqual([
      [{ screen: 'home' }],
      [{ lessons: 3, pro: false }],
    ]);
    expect(mockNative.removeTriggers).toHaveBeenCalledWith(['screen']);
    expect(mockNative.clearTriggers).toHaveBeenCalled();
    expect(() => Dak.addTrigger('bad key', 1)).toThrow(DakError);
    expect(() => Dak.addTrigger('k', null as never)).toThrow(DakError);
  });

  it('gives each block its own id and ends it once', () => {
    const a = Dak.blockInApp();
    const b = Dak.blockInApp();
    const [[idA], [idB]] = mockNative.blockInApp.mock.calls;
    expect(idA).not.toBe(idB);
    a.end();
    a.end();
    b.end();
    expect(mockNative.endInAppBlock.mock.calls).toEqual([[idA], [idB]]);
  });

  it('pauses', () => {
    Dak.pauseInApp(true);
    Dak.pauseInApp(false);
    expect(mockNative.pauseInApp.mock.calls).toEqual([[true], [false]]);
  });
});

describe('events', () => {
  it('delivers taps with every field', async () => {
    const got: unknown[] = [];
    const sub = Dak.onOpened((n) => got.push(n));
    expect(mockNative.addListener).toHaveBeenCalledWith('DakPush.opened');
    DeviceEventEmitter.emit(
      'DakPush.opened',
      notification('m1', { actionId: 'yes' })
    );
    expect(got).toEqual([
      expect.objectContaining({ id: 'm1', actionId: 'yes', isSilent: false }),
    ]);
    sub.remove();
  });

  it('keeps taps for the next listener while none is added', async () => {
    const first = Dak.onOpened(() => {});
    first.remove();
    DeviceEventEmitter.emit('DakPush.opened', notification('kept-1'));
    DeviceEventEmitter.emit('DakPush.opened', notification('kept-2'));
    const got: string[] = [];
    const sub = Dak.onOpened((n) => got.push(n.id as string));
    expect(got).toEqual([]); // after the caller's own setup
    await flushPromises();
    expect(got).toEqual(['kept-1', 'kept-2']);
    sub.remove();
  });

  it('keeps 20 taps at most, the newest', async () => {
    for (let i = 0; i < 25; i++)
      DeviceEventEmitter.emit('DakPush.opened', notification(`t${i}`));
    const got: string[] = [];
    const sub = Dak.onOpened((n) => got.push(n.id as string));
    await flushPromises();
    expect(got).toHaveLength(20);
    expect(got[0]).toBe('t5');
    sub.remove();
  });

  it('does not keep foreground messages', async () => {
    const first = Dak.onForeground(() => {});
    first.remove();
    DeviceEventEmitter.emit('DakPush.foreground', notification('f1'));
    const got: unknown[] = [];
    const sub = Dak.onForeground((n) => got.push(n));
    await flushPromises();
    expect(got).toEqual([]);
    DeviceEventEmitter.emit('DakPush.foreground', notification('f2'));
    expect(got).toHaveLength(1);
    sub.remove();
  });

  it('delivers in-app clicks and errors', () => {
    const clicks: unknown[] = [];
    const errors: DakError[] = [];
    const a = Dak.onInAppClick((c) => clicks.push(c));
    const b = Dak.onError((e) => errors.push(e));
    DeviceEventEmitter.emit('DakPush.inAppClick', {
      messageId: 'm',
      buttonId: 'join',
      actionType: 'deep_link',
      url: 'app://join',
      tags: {},
    });
    DeviceEventEmitter.emit('DakPush.error', {
      message: 'bad tag',
      code: 'invalid',
      field: 'tags',
      status: 422,
    });
    expect(clicks).toEqual([
      {
        messageId: 'm',
        buttonId: 'join',
        actionType: 'deep_link',
        url: 'app://join',
        tags: {},
      },
    ]);
    expect(errors[0]).toBeInstanceOf(DakError);
    expect([errors[0]!.code, errors[0]!.status]).toEqual(['invalid', 422]);
    a.remove();
    b.remove();
  });

  it('keeps calling the other listeners when one throws', () => {
    const spy = jest.spyOn(console, 'error').mockImplementation(() => {});
    const got: string[] = [];
    const a = Dak.onForeground(() => {
      throw new Error('mine');
    });
    const b = Dak.onForeground((n) => got.push(n.id as string));
    DeviceEventEmitter.emit('DakPush.foreground', notification('f3'));
    expect(got).toEqual(['f3']);
    expect(spy).toHaveBeenCalled();
    a.remove();
    b.remove();
    spy.mockRestore();
  });

  it('gives the device id now and when it changes, never twice in a row', async () => {
    mockNative.getDeviceId.mockResolvedValue('dev-1');
    const got: string[] = [];
    const sub = Dak.onDeviceId((id) => got.push(id));
    await flushPromises();
    DeviceEventEmitter.emit('DakPush.deviceId', 'dev-1');
    DeviceEventEmitter.emit('DakPush.deviceId', 'dev-2');
    DeviceEventEmitter.emit('DakPush.deviceId', 'dev-2');
    expect(got).toEqual(['dev-1', 'dev-2']);
    sub.remove();
    DeviceEventEmitter.emit('DakPush.deviceId', 'dev-3');
    expect(got).toEqual(['dev-1', 'dev-2']);
  });

  it('reads the notification that opened the app', async () => {
    mockNative.getInitialNotification.mockResolvedValueOnce(
      notification('launch')
    );
    await expect(Dak.getInitialNotification()).resolves.toMatchObject({
      id: 'launch',
    });
    mockNative.getInitialNotification.mockResolvedValueOnce(null);
    await expect(Dak.getInitialNotification()).resolves.toBeNull();
  });
});

describe('results', () => {
  it('resolves calls without a result to undefined, whatever the platform sends', async () => {
    mockNative.login.mockResolvedValue(null); // Android
    mockNative.flush.mockResolvedValue(undefined); // iOS
    mockNative.setTags.mockResolvedValue(null);
    await expect(Dak.login('u')).resolves.toBeUndefined();
    await expect(Dak.flush()).resolves.toBeUndefined();
    await expect(Dak.setTag('a', 1)).resolves.toBeUndefined();
  });
});
