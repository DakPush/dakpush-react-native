import * as fs from 'fs';
import * as path from 'path';

import {
  withDangerousMod,
  withEntitlementsPlist,
  withInfoPlist,
  withPodfile,
  withXcodeProject,
  type ConfigPlugin,
} from '@expo/config-plugins';

import type { ResolvedProps } from './props';

type PlistValue = string | number | boolean | string[];

/** Info.plist → `DakPush`: what the bridge starts the SDK with. */
export function iosPlistDict(p: ResolvedProps): Record<string, PlistValue> {
  const d: Record<string, PlistValue> = {
    AppId: p.appId,
    BaseURL: p.baseUrl,
    ShowInForeground: p.showInForeground,
    ShareTimezoneOffset: p.shareTimezoneOffset,
    DebugLogs: p.debugLogs,
    InAppMessages: p.inAppMessages,
    SessionTimeout: p.sessionTimeout,
    InAppUrlSchemes: p.inAppUrlSchemes,
    AppDelegateProxy: p.ios.appDelegateProxy,
  };
  if (p.ios.appGroup) d.AppGroup = p.ios.appGroup;
  return d;
}

const POD_BEGIN = '# @generated begin dakpush-react-native';
const POD_END = '# @generated end dakpush-react-native';

/**
 * The Podfile with the extension's target added (or replaced, between the
 * markers, on a later prebuild).
 */
export function podfileWithExtension(
  contents: string,
  target: string,
  podPath: string
): string {
  const block = [
    POD_BEGIN,
    `target '${target}' do`,
    `  pod 'DakPushExtension', :path => '${podPath}'`,
    'end',
    POD_END,
  ].join('\n');
  const start = contents.indexOf(POD_BEGIN);
  const end = contents.indexOf(POD_END);
  if (start >= 0 && end > start) {
    return (
      contents.slice(0, start) + block + contents.slice(end + POD_END.length)
    );
  }
  return `${contents.replace(/\s*$/, '')}\n\n${block}\n`;
}

/** The Podfile without the extension's target (when it was turned off). */
export function podfileWithoutExtension(contents: string): string {
  const start = contents.indexOf(POD_BEGIN);
  const end = contents.indexOf(POD_END);
  if (start < 0 || end < start) return contents;
  return (
    contents.slice(0, start).replace(/\s*$/, '\n') +
    contents.slice(end + POD_END.length).replace(/^\n+/, '')
  );
}

export const EXTENSION_SOURCE = `import DakPushExtension

/// DakPush's notification service: the push's image, its buttons, badge
/// increments and the delivery receipt. The App Group comes from DakAppGroup
/// in this extension's Info.plist. Made by the dakpush-react-native Expo
/// plugin; override willDeliver(_:for:) here to change the content yourself.
final class NotificationService: DakNotificationService {}
`;

function xmlEscape(s: string): string {
  return s.replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;');
}

export function extensionInfoPlist(
  appGroup: string,
  version: string,
  build: string
): string {
  return `<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleDevelopmentRegion</key>
	<string>$(DEVELOPMENT_LANGUAGE)</string>
	<key>CFBundleDisplayName</key>
	<string>$(PRODUCT_NAME)</string>
	<key>CFBundleExecutable</key>
	<string>$(EXECUTABLE_NAME)</string>
	<key>CFBundleIdentifier</key>
	<string>$(PRODUCT_BUNDLE_IDENTIFIER)</string>
	<key>CFBundleInfoDictionaryVersion</key>
	<string>6.0</string>
	<key>CFBundleName</key>
	<string>$(PRODUCT_NAME)</string>
	<key>CFBundlePackageType</key>
	<string>$(PRODUCT_BUNDLE_PACKAGE_TYPE)</string>
	<key>CFBundleShortVersionString</key>
	<string>${xmlEscape(version)}</string>
	<key>CFBundleVersion</key>
	<string>${xmlEscape(build)}</string>
	<key>DakAppGroup</key>
	<string>${xmlEscape(appGroup)}</string>
	<key>NSExtension</key>
	<dict>
		<key>NSExtensionPointIdentifier</key>
		<string>com.apple.usernotifications.service</string>
		<key>NSExtensionPrincipalClass</key>
		<string>$(PRODUCT_MODULE_NAME).NotificationService</string>
	</dict>
</dict>
</plist>
`;
}

export function extensionEntitlements(appGroup: string): string {
  return `<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>com.apple.security.application-groups</key>
	<array>
		<string>${xmlEscape(appGroup)}</string>
	</array>
</dict>
</plist>
`;
}

/** This package's root, where ios/DakPushExtension.podspec is. */
function packageRoot(): string {
  return path.resolve(__dirname, '..', '..');
}

const withSettings: ConfigPlugin<ResolvedProps> = (config, p) => {
  config = withInfoPlist(config, (c) => {
    c.modResults.DakPush = iosPlistDict(p);
    const modes = new Set<string>(
      (c.modResults.UIBackgroundModes as string[] | undefined) ?? []
    );
    // Silent pushes wake the app, so they count as delivered.
    modes.add('remote-notification');
    c.modResults.UIBackgroundModes = [...modes];
    return c;
  });
  return withEntitlementsPlist(config, (c) => {
    c.modResults['aps-environment'] = p.ios.mode;
    if (p.ios.appGroup) {
      const key = 'com.apple.security.application-groups';
      const groups = new Set<string>(
        (c.modResults[key] as string[] | undefined) ?? []
      );
      groups.add(p.ios.appGroup);
      c.modResults[key] = [...groups];
    }
    return c;
  });
};

const withExtensionFiles: ConfigPlugin<ResolvedProps> = (config, p) =>
  withDangerousMod(config, [
    'ios',
    async (c) => {
      const target = p.ios.extensionTargetName;
      const dir = path.join(c.modRequest.platformProjectRoot, target);
      fs.mkdirSync(dir, { recursive: true });
      const group = p.ios.appGroup as string;
      fs.writeFileSync(
        path.join(dir, 'NotificationService.swift'),
        EXTENSION_SOURCE
      );
      fs.writeFileSync(
        path.join(dir, 'Info.plist'),
        extensionInfoPlist(
          group,
          c.version ?? '1.0.0',
          c.ios?.buildNumber ?? '1'
        )
      );
      fs.writeFileSync(
        path.join(dir, `${target}.entitlements`),
        extensionEntitlements(group)
      );
      return c;
    },
  ]);

const withExtensionPod: ConfigPlugin<ResolvedProps> = (config, p) =>
  withPodfile(config, (c) => {
    if (!p.ios.extension) {
      c.modResults.contents = podfileWithoutExtension(c.modResults.contents);
      return c;
    }
    const iosDir = c.modRequest.platformProjectRoot;
    const podPath = path
      .relative(iosDir, path.join(packageRoot(), 'ios'))
      .split(path.sep)
      .join('/');
    c.modResults.contents = podfileWithExtension(
      c.modResults.contents,
      p.ios.extensionTargetName,
      podPath
    );
    return c;
  });

type XcodeProject = any; // the `xcode` package has no types

function quoted(s: string): string {
  return `"${s}"`;
}

/** The app target's deployment target, so the extension runs where the app does. */
function appDeploymentTarget(project: XcodeProject): string {
  const configs = project.pbxXCBuildConfigurationSection();
  for (const key of Object.keys(configs)) {
    const v = configs[key]?.buildSettings?.IPHONEOS_DEPLOYMENT_TARGET;
    if (typeof v === 'string' && v.length > 0) return v.replace(/"/g, '');
  }
  return '15.1';
}

const withExtensionTarget: ConfigPlugin<ResolvedProps> = (config, p) =>
  withXcodeProject(config, (c) => {
    const project: XcodeProject = c.modResults;
    const target = p.ios.extensionTargetName;
    if (project.pbxTargetByName(target)) return c;
    const bundleId = c.ios?.bundleIdentifier;
    if (!bundleId)
      throw new Error('dakpush-react-native: set ios.bundleIdentifier');

    const objects = project.hash.project.objects;
    objects.PBXTargetDependency = objects.PBXTargetDependency ?? {};
    objects.PBXContainerItemProxy = objects.PBXContainerItemProxy ?? {};

    const files = [
      'NotificationService.swift',
      'Info.plist',
      `${target}.entitlements`,
    ];
    const group = project.addPbxGroup(files, target, target);
    const groups = objects.PBXGroup;
    for (const key of Object.keys(groups)) {
      const g = groups[key];
      // The main group has neither name nor path.
      if (
        typeof g === 'object' &&
        g.name === undefined &&
        g.path === undefined
      ) {
        project.addToPbxGroup(group.uuid, key);
      }
    }

    const deployment = appDeploymentTarget(project);
    const t = project.addTarget(
      target,
      'app_extension',
      target,
      `${bundleId}.${target}`
    );
    project.addBuildPhase(
      ['NotificationService.swift'],
      'PBXSourcesBuildPhase',
      'Sources',
      t.uuid
    );
    project.addBuildPhase([], 'PBXResourcesBuildPhase', 'Resources', t.uuid);
    project.addBuildPhase([], 'PBXFrameworksBuildPhase', 'Frameworks', t.uuid);

    const configs = project.pbxXCBuildConfigurationSection();
    for (const key of Object.keys(configs)) {
      const settings = configs[key]?.buildSettings;
      if (!settings || settings.PRODUCT_NAME !== quoted(target)) continue;
      Object.assign(settings, {
        CODE_SIGN_ENTITLEMENTS: quoted(`${target}/${target}.entitlements`),
        CODE_SIGN_STYLE: 'Automatic',
        INFOPLIST_FILE: quoted(`${target}/Info.plist`),
        GENERATE_INFOPLIST_FILE: 'NO',
        IPHONEOS_DEPLOYMENT_TARGET: deployment,
        PRODUCT_BUNDLE_IDENTIFIER: quoted(`${bundleId}.${target}`),
        SWIFT_VERSION: '5.0',
        TARGETED_DEVICE_FAMILY: quoted('1,2'),
        ENABLE_USER_SCRIPT_SANDBOXING: 'NO',
        SKIP_INSTALL: 'YES',
      });
      if (c.ios?.appleTeamId) settings.DEVELOPMENT_TEAM = c.ios.appleTeamId;
    }
    if (c.ios?.appleTeamId) {
      project.addTargetAttribute('DevelopmentTeam', c.ios.appleTeamId, t);
    }
    return c;
  });

/** EAS Build signs the extension too when it knows about it. */
const withEasExtension: ConfigPlugin<ResolvedProps> = (config, p) => {
  const bundleId = config.ios?.bundleIdentifier;
  if (!bundleId) return config;
  config.extra = config.extra ?? {};
  const eas = (config.extra.eas = config.extra.eas ?? {});
  eas.build = eas.build ?? {};
  eas.build.experimental = eas.build.experimental ?? {};
  eas.build.experimental.ios = eas.build.experimental.ios ?? {};
  const list: Array<Record<string, unknown>> =
    eas.build.experimental.ios.appExtensions ?? [];
  const target = p.ios.extensionTargetName;
  if (!list.some((e) => e.targetName === target)) {
    list.push({
      targetName: target,
      bundleIdentifier: `${bundleId}.${target}`,
      entitlements: {
        'com.apple.security.application-groups': [p.ios.appGroup],
      },
    });
  }
  eas.build.experimental.ios.appExtensions = list;
  return config;
};

export const withDakPushIos: ConfigPlugin<ResolvedProps> = (config, p) => {
  config = withSettings(config, p);
  config = withExtensionPod(config, p);
  if (!p.ios.extension) return config;
  config = withEasExtension(config, p);
  config = withExtensionFiles(config, p);
  return withExtensionTarget(config, p);
};
