import { useCallback, useEffect, useState } from 'react';
import {
  Platform,
  Pressable,
  ScrollView,
  StyleSheet,
  Text,
  View,
  useColorScheme,
} from 'react-native';
import {
  Dak,
  useInAppBlock,
  type DakNotification,
  type DakState,
} from 'dakpush-react-native';

type Line = { at: string; text: string };

const RED = '#D92D20';

function time(): string {
  return new Date().toISOString().slice(11, 19);
}

function describe(n: DakNotification): string {
  return `${n.id ?? '-'} "${n.title ?? ''}"${n.actionId ? ` button=${n.actionId}` : ''}${
    n.url ? ` url=${n.url}` : ''
  }`;
}

export default function App() {
  const dark = useColorScheme() === 'dark';
  const c = dark ? colors.dark : colors.light;
  const [state, setState] = useState<DakState | null>(null);
  const [deviceId, setDeviceId] = useState<string | null>(null);
  const [permission, setPermission] = useState<boolean | null>(null);
  const [paused, setPaused] = useState(false);
  const [blocked, setBlocked] = useState(false);
  const [lines, setLines] = useState<Line[]>([]);

  const log = useCallback((text: string) => {
    // Also in Logcat / the Xcode console, for checks from the command line.
    console.log(`[dak-example] ${text}`);
    setLines((l) => [{ at: time(), text }, ...l].slice(0, 40));
  }, []);

  useInAppBlock(blocked);

  useEffect(() => {
    const subs = [
      Dak.onOpened((n) => log(`opened ${describe(n)}`)),
      Dak.onForeground((n) => log(`foreground ${describe(n)}`)),
      Dak.onInAppClick((x) =>
        log(
          `in-app click ${x.messageId} button=${x.buttonId ?? '-'} ${x.actionType} ${x.url ?? ''}`
        )
      ),
      Dak.onError((e) =>
        log(`error ${e.code}${e.field ? ` ${e.field}` : ''}: ${e.message}`)
      ),
      Dak.onDeviceId((id) => {
        setDeviceId(id);
        log(`device id ${id}`);
      }),
    ];
    Dak.getState().then(setState, (e) => log(`state: ${e.message}`));
    Dak.hasPermission().then(setPermission, () => {});
    Dak.getInitialNotification().then(
      (n) => n && log(`initial ${describe(n)}`)
    );
    Dak.addTrigger('screen', 'home');
    return () => subs.forEach((s) => s.remove());
  }, [log]);

  const run =
    (label: string, f: () => Promise<unknown> | unknown) => async () => {
      try {
        const r = await f();
        log(`${label}${r === undefined ? '' : ` → ${JSON.stringify(r)}`}`);
      } catch (e) {
        const err = e as { code?: string; message?: string };
        log(`${label} failed: ${err.code ?? ''} ${err.message ?? String(e)}`);
      }
    };

  const buttons: Array<[string, () => void]> = [
    [
      Platform.OS === 'ios' ? 'Allow (provisional)' : 'Allow notifications',
      run('permission', async () => {
        const ok = await Dak.requestPermission({
          provisional: Platform.OS === 'ios',
        });
        setPermission(ok);
        return ok;
      }),
    ],
    ['Log in rn-user-1', run('login', () => Dak.login('rn-user-1'))],
    ['Log out', run('logout', () => Dak.logout())],
    [
      'Tag level=b2',
      run('tags', () => Dak.setTags({ level: 'b2', lessons: 3, pro: true })),
    ],
    ['Trigger cart=1', run('trigger cart', () => Dak.addTrigger('cart', 1))],
    ['Remove cart', run('remove cart', () => Dak.removeTrigger('cart'))],
    [
      paused ? 'Resume in-app' : 'Pause in-app',
      run('pause', () => {
        Dak.pauseInApp(!paused);
        setPaused(!paused);
        return !paused;
      }),
    ],
    [
      blocked ? 'End block' : 'Block in-app',
      run('block', () => {
        setBlocked(!blocked);
        return !blocked;
      }),
    ],
    ['Refresh in-app', run('refresh', () => Dak.refreshInApp())],
    ['Is paused?', run('paused?', () => Dak.isInAppPaused())],
    ['Flush', run('flush', () => Dak.flush())],
  ];

  return (
    <ScrollView
      style={{ backgroundColor: c.bg }}
      contentContainerStyle={styles.page}
      testID="example-scroll"
    >
      <Text style={[styles.title, { color: c.fg }]}>DakPush React Native</Text>
      <View style={[styles.card, { borderColor: c.line }]}>
        <Row
          k="SDK"
          v={
            state
              ? `${state.sdkVersion} ${state.started ? 'started' : 'not started'}`
              : '…'
          }
          c={c}
        />
        <Row k="Server" v={state?.baseUrl ?? '-'} c={c} />
        <Row k="App" v={state?.appId ?? '-'} c={c} />
        <Row
          k="Device"
          v={deviceId ?? 'not registered yet'}
          c={c}
          testID="device-id"
        />
        <Row
          k="Permission"
          v={permission === null ? '…' : String(permission)}
          c={c}
        />
      </View>
      <View style={styles.buttons}>
        {buttons.map(([label, onPress]) => (
          <Pressable
            key={label}
            onPress={onPress}
            accessibilityRole="button"
            testID={label}
            style={({ pressed }) => [
              styles.button,
              { backgroundColor: c.fg, opacity: pressed ? 0.7 : 1 },
            ]}
          >
            <Text style={[styles.buttonText, { color: c.bg }]}>{label}</Text>
          </Pressable>
        ))}
      </View>
      <Text style={[styles.section, { color: RED }]}>Events</Text>
      {lines.length === 0 ? (
        <Text style={{ color: c.muted }}>Nothing yet.</Text>
      ) : null}
      {lines.map((l, i) => (
        <Text key={i} style={[styles.line, { color: c.fg }]} selectable>
          <Text style={{ color: c.muted }}>{l.at} </Text>
          {l.text}
        </Text>
      ))}
    </ScrollView>
  );
}

function Row(props: {
  k: string;
  v: string;
  c: (typeof colors)['light'];
  testID?: string;
}) {
  return (
    <View style={styles.row}>
      <Text style={[styles.key, { color: props.c.muted }]}>{props.k}</Text>
      <Text
        style={[styles.value, { color: props.c.fg }]}
        testID={props.testID}
        selectable
      >
        {props.v}
      </Text>
    </View>
  );
}

const colors = {
  light: { bg: '#FFFFFF', fg: '#0A0A0A', muted: '#6B6B6B', line: '#E5E5E5' },
  dark: { bg: '#0A0A0A', fg: '#FAFAFA', muted: '#A3A3A3', line: '#262626' },
};

const styles = StyleSheet.create({
  page: { padding: 20, paddingTop: 64, gap: 12 },
  title: { fontSize: 22, fontWeight: '700' },
  card: { borderWidth: 1, borderRadius: 12, padding: 12, gap: 6 },
  row: { flexDirection: 'row', gap: 8 },
  key: { width: 84, fontSize: 13 },
  value: { flex: 1, fontSize: 13 },
  buttons: { flexDirection: 'row', flexWrap: 'wrap', gap: 8 },
  button: { paddingHorizontal: 14, paddingVertical: 10, borderRadius: 999 },
  buttonText: { fontSize: 14, fontWeight: '600' },
  section: {
    marginTop: 8,
    fontSize: 13,
    fontWeight: '700',
    letterSpacing: 0.5,
  },
  line: {
    fontSize: 12,
    fontFamily: Platform.select({ ios: 'Menlo', default: 'monospace' }),
  },
});
