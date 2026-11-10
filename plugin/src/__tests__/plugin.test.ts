import { androidMetaData, withDakPushAndroid } from '../android';
import {
  extensionEntitlements,
  extensionInfoPlist,
  iosPlistDict,
  podfileWithExtension,
  podfileWithoutExtension,
  withDakPushIos,
} from '../ios';
import { resolveProps } from '../props';

const base = {
  appId: '01a15a03-86ed-7ea0-bf12-c1a457202c12',
  baseUrl: 'https://push.example.com/',
};

describe('resolveProps', () => {
  it('fills in the defaults', () => {
    expect(resolveProps(base, 'com.example.app')).toEqual({
      appId: base.appId,
      baseUrl: 'https://push.example.com',
      showInForeground: false,
      shareTimezoneOffset: false,
      debugLogs: false,
      inAppMessages: true,
      sessionTimeout: 300,
      inAppUrlSchemes: ['https', 'http'],
      android: { useFid: true, openAppOnTap: true },
      ios: {
        mode: 'development',
        appGroup: 'group.com.example.app.dakpush',
        extension: true,
        extensionTargetName: 'DakPushNotificationService',
        appDelegateProxy: true,
      },
    });
  });

  it.each([
    [{}, /appId/],
    [{ appId: 'a' }, /baseUrl/],
    [{ appId: 'a', baseUrl: 'push.example.com' }, /not a URL/],
    [{ appId: 'a', baseUrl: 'http://push.example.com' }, /https/],
    [{ appId: 'a', baseUrl: 'https://push.example.com/v1' }, /without \/v1/],
    [{ ...base, sessionTimeout: -1 }, /sessionTimeout/],
    [{ ...base, inAppUrlSchemes: ['ht tp'] }, /inAppUrlSchemes/],
    [{ ...base, ios: { mode: 'prod' } }, /ios.mode/],
    [{ ...base, ios: { appGroup: 'com.example' } }, /group\./],
    [
      { ...base, ios: { extensionTargetName: 'My Ext' } },
      /extensionTargetName/,
    ],
  ])('refuses %p', (props: object, message: RegExp) => {
    expect(() => resolveProps(props as never, 'com.example.app')).toThrow(
      message
    );
  });

  it('takes plain http for local servers only', () => {
    for (const host of ['localhost:8095', '127.0.0.1:8095', '10.0.2.2:8095']) {
      expect(
        resolveProps({ appId: 'a', baseUrl: `http://${host}` }, 'x').baseUrl
      ).toBe(`http://${host}`);
    }
  });

  it('adds no extension without an App Group', () => {
    const p = resolveProps(
      { ...base, ios: { appGroup: false } },
      'com.example.app'
    );
    expect([p.ios.appGroup, p.ios.extension]).toEqual([null, false]);
    expect(resolveProps(base, undefined).ios.extension).toBe(false);
  });
});

describe('Android', () => {
  it('writes the settings as meta-data', () => {
    const p = resolveProps(
      {
        ...base,
        debugLogs: true,
        sessionTimeout: 60,
        inAppUrlSchemes: ['https', 'mailto'],
      },
      'x'
    );
    expect(Object.fromEntries(androidMetaData(p))).toEqual({
      'dakpush.app_id': base.appId,
      'dakpush.base_url': 'https://push.example.com',
      'dakpush.show_in_foreground': 'false',
      'dakpush.share_timezone_offset': 'false',
      'dakpush.debug_logs': 'true',
      'dakpush.in_app_messages': 'true',
      'dakpush.session_timeout': '60',
      'dakpush.in_app_url_schemes': 'https,mailto',
      'dakpush.use_fid': 'true',
      'dakpush.open_app_on_tap': 'true',
    });
  });

  it('replaces earlier dakpush meta-data and keeps the app’s own', async () => {
    const config: any = withDakPushAndroid(
      { name: 'x', slug: 'x', android: { googleServicesFile: './g.json' } },
      resolveProps(base, 'x')
    );
    const manifest = {
      manifest: {
        $: {},
        application: [
          {
            '$': { 'android:name': '.MainApplication' },
            'meta-data': [
              {
                $: {
                  'android:name': 'dakpush.debug_logs',
                  'android:value': 'true',
                },
              },
              {
                $: {
                  'android:name': 'dakpush.old_option',
                  'android:value': 'x',
                },
              },
              {
                $: {
                  'android:name': 'com.example.mine',
                  'android:value': 'kept',
                },
              },
            ],
          },
        ],
      },
    };
    const out = await config.mods.android.manifest({
      ...config,
      modResults: manifest,
      modRequest: {},
    });
    const md = out.modResults.manifest.application[0]['meta-data'].map(
      (m: any) => [m.$['android:name'], m.$['android:value']]
    );
    expect(md).toContainEqual(['com.example.mine', 'kept']);
    expect(md).toContainEqual(['dakpush.debug_logs', 'false']);
    expect(md).toContainEqual(['dakpush.app_id', base.appId]);
    expect(md.map((m: string[]) => m[0])).not.toContain('dakpush.old_option');
    expect(
      md.filter((m: string[]) => m[0] === 'dakpush.debug_logs')
    ).toHaveLength(1);
  });
});

describe('iOS', () => {
  it('writes the DakPush dictionary', () => {
    const p = resolveProps(
      { ...base, showInForeground: true, ios: { appDelegateProxy: false } },
      'com.example.app'
    );
    expect(iosPlistDict(p)).toEqual({
      AppId: base.appId,
      BaseURL: 'https://push.example.com',
      ShowInForeground: true,
      ShareTimezoneOffset: false,
      DebugLogs: false,
      InAppMessages: true,
      SessionTimeout: 300,
      InAppUrlSchemes: ['https', 'http'],
      AppDelegateProxy: false,
      AppGroup: 'group.com.example.app.dakpush',
    });
  });

  it('sets Info.plist, entitlements and the background mode', async () => {
    const p = resolveProps(
      { ...base, ios: { mode: 'production' } },
      'com.example.app'
    );
    const config: any = withDakPushIos(
      { name: 'x', slug: 'x', ios: { bundleIdentifier: 'com.example.app' } },
      p
    );
    const plist = await config.mods.ios.infoPlist({
      ...config,
      modResults: { UIBackgroundModes: ['audio'] },
      modRequest: {},
    });
    expect(plist.modResults.UIBackgroundModes).toEqual([
      'audio',
      'remote-notification',
    ]);
    expect(plist.modResults.DakPush.AppId).toBe(base.appId);
    const ent = await config.mods.ios.entitlements({
      ...config,
      modResults: { 'com.apple.security.application-groups': ['group.other'] },
      modRequest: {},
    });
    expect(ent.modResults).toEqual({
      'aps-environment': 'production',
      'com.apple.security.application-groups': [
        'group.other',
        'group.com.example.app.dakpush',
      ],
    });
    expect(config.extra.eas.build.experimental.ios.appExtensions).toEqual([
      {
        targetName: 'DakPushNotificationService',
        bundleIdentifier: 'com.example.app.DakPushNotificationService',
        entitlements: {
          'com.apple.security.application-groups': [
            'group.com.example.app.dakpush',
          ],
        },
      },
    ]);
  });

  it('adds the extension target to the Podfile once', () => {
    const podfile =
      "platform :ios, '15.1'\n\ntarget 'App' do\n  use_expo_modules!\nend\n";
    const once = podfileWithExtension(
      podfile,
      'DakPushNotificationService',
      '../node_modules/dakpush-react-native/ios'
    );
    expect(once).toContain("target 'DakPushNotificationService' do");
    expect(once).toContain(
      "pod 'DakPushExtension', :path => '../node_modules/dakpush-react-native/ios'"
    );
    const twice = podfileWithExtension(
      once,
      'DakPushNotificationService',
      '../other/ios'
    );
    expect(twice.match(/DakPushExtension/g)).toHaveLength(1);
    expect(twice).toContain("'../other/ios'");
    expect(podfileWithoutExtension(twice)).toBe(podfile);
    expect(podfileWithoutExtension(podfile)).toBe(podfile);
  });

  it('writes the extension’s Info.plist and entitlements', () => {
    const info = extensionInfoPlist(
      'group.com.example.app.dakpush',
      '2.1.0',
      '45'
    );
    expect(info).toContain(
      '<key>DakAppGroup</key>\n\t<string>group.com.example.app.dakpush</string>'
    );
    expect(info).toContain(
      '<string>com.apple.usernotifications.service</string>'
    );
    expect(info).toContain(
      '<string>$(PRODUCT_MODULE_NAME).NotificationService</string>'
    );
    expect(info).toContain('<string>2.1.0</string>');
    expect(info).toContain('<string>45</string>');
    expect(extensionEntitlements('group.a&b')).toContain(
      '<string>group.a&amp;b</string>'
    );
  });
});
