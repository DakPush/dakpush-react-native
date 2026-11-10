/**
 * React Native SDK for DakPush.
 *
 * ```ts
 * import { Dak } from 'dakpush-react-native';
 *
 * await Dak.requestPermission();
 * await Dak.login(userId, hashFromYourServer);
 * Dak.onOpened((n) => openRoute(n.url));
 * Dak.addTrigger('screen', 'home');
 * Dak.onInAppClick((c) => c.actionType === 'deep_link' && openRoute(c.url));
 * ```
 */
export { Dak } from './Dak';
export { DakError } from './errors';
export { useInAppBlock } from './hooks';
export type {
  DakButton,
  DakInAppActionType,
  DakInAppBlock,
  DakInAppClick,
  DakNotification,
  DakState,
  DakSubscription,
  DakTagValue,
  DakTriggerValue,
} from './types';
