jest.mock('../NativeDakPush', () => ({ __esModule: true, default: null }));

import { Dak, DakError } from '../index';

describe('a build without the native module (Expo Go, web)', () => {
  it('rejects calls and warns once for the others', async () => {
    const warn = jest.spyOn(console, 'warn').mockImplementation(() => {});
    const e = await Dak.login('user-1').catch((x) => x);
    expect(e).toBeInstanceOf(DakError);
    expect(e.code).toBe('unavailable');
    await expect(Dak.getState()).rejects.toMatchObject({ code: 'unavailable' });
    Dak.addTrigger('screen', 'home');
    Dak.pauseInApp(true);
    Dak.blockInApp().end();
    Dak.openNotificationSettings();
    expect(warn).toHaveBeenCalledTimes(1);
    expect(warn.mock.calls[0]![0]).toMatch(/Expo Go/);
    warn.mockRestore();
  });

  it('still takes listeners', () => {
    const sub = Dak.onOpened(() => {});
    expect(typeof sub.remove).toBe('function');
    sub.remove();
  });

  it('reports the missing module first, and still checks triggers', async () => {
    await expect(Dak.setTags({ 'bad key': 1 })).rejects.toMatchObject({
      code: 'unavailable',
    });
    expect(() => Dak.addTrigger('bad key', 1)).toThrow(DakError);
  });
});
