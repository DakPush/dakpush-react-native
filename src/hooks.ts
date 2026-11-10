import { useEffect } from 'react';

import { Dak } from './Dak';

/**
 * Keeps in-app messages away while the component is mounted and `active` is
 * true, for a screen that must stay clear (a call, a payment, a video).
 * Blocks nest: messages come back when the last one ends.
 *
 * ```tsx
 * function CallScreen() {
 *   useInAppBlock();
 *   return <Call />;
 * }
 * ```
 */
export function useInAppBlock(active: boolean = true): void {
  useEffect(() => {
    if (!active) return undefined;
    const block = Dak.blockInApp();
    return () => block.end();
  }, [active]);
}
