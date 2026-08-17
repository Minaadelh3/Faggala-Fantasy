import { describe, expect, it } from 'vitest';
import { formationValid, transferPenalty } from './fantasyRules';
import type { FantasyRules, PlayerPosition } from '../types/database';

const rules = {
  lineup_size: 7,
  lineup_min: { GK: 1, DEF: 2, MID: 2, FWD: 1 },
  lineup_max: { GK: 1, DEF: 3, MID: 3, FWD: 2 },
} satisfies Pick<FantasyRules, 'lineup_size' | 'lineup_min' | 'lineup_max'>;

describe('configured Fantasy rules', () => {
  it('uses the league formation instead of fixed UI constants', () => {
    const positions: PlayerPosition[] = ['GK', 'DEF', 'DEF', 'MID', 'MID', 'FWD', 'FWD'];
    expect(formationValid(positions.map((position) => ({ position })), rules)).toBe(true);
    expect(formationValid(positions.slice(0, 6).map((position) => ({ position })), rules)).toBe(false);
  });

  it('uses the configured extra-transfer cost', () => {
    expect(transferPenalty(1, 3, 6)).toBe(12);
  });
});
