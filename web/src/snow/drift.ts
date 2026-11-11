/**
 * A snow drift lying on a horizontal edge, stored as a height map.
 *
 * Heights are in CSS pixels and grow upwards from the edge. Coordinates passed
 * in are local to the edge: 0 is its left end, `width` its right end.
 */

/** Horizontal size of one height-map cell, px. */
export const CELL = 3;
/** Steepest slope the snow can hold (rise over run) before it slumps. */
const REPOSE_SLOPE = 0.85;
/** Steepest slope allowed at the very ends, where the snow overhangs the edge. */
const EDGE_SLOPE = 0.55;
/** Absolute cap on drift height, px. */
export const MAX_HEIGHT = 46;

export interface Spill {
  /** Local x the snow fell from. */
  x: number;
  /** Amount in px·cell units. */
  amount: number;
}

export class Drift {
  width: number;
  heights: Float32Array;
  private scratch: Float32Array;

  constructor(width: number) {
    this.width = width;
    const n = Drift.cellsFor(width);
    this.heights = new Float32Array(n);
    this.scratch = new Float32Array(n);
  }

  private static cellsFor(width: number): number {
    return Math.max(2, Math.ceil(width / CELL));
  }

  get cells(): number {
    return this.heights.length;
  }

  /** Re-sample to a new width, keeping the overall shape. */
  resize(width: number): void {
    if (width === this.width) return;
    const n = Drift.cellsFor(width);
    const next = new Float32Array(n);
    const old = this.heights;
    for (let i = 0; i < n; i++) {
      const t = (i / Math.max(1, n - 1)) * (old.length - 1);
      const a = Math.floor(t);
      const b = Math.min(old.length - 1, a + 1);
      next[i] = old[a]! + (old[b]! - old[a]!) * (t - a);
    }
    this.width = width;
    this.heights = next;
    this.scratch = new Float32Array(n);
  }

  cellAt(x: number): number {
    return Math.min(this.cells - 1, Math.max(0, Math.floor(x / CELL)));
  }

  /** Smoothly interpolated height at local x. */
  heightAt(x: number): number {
    if (x < 0 || x > this.width) return 0;
    const t = x / CELL - 0.5;
    const a = Math.max(0, Math.floor(t));
    const b = Math.min(this.cells - 1, a + 1);
    const f = Math.min(1, Math.max(0, t - a));
    return this.heights[a]! * (1 - f) + this.heights[b]! * f;
  }

  /**
   * Drops snow around x using a small tent kernel so banks stay rounded.
   * Near the height cap the snow packs down, so growth eases off instead of
   * flattening into a hard shelf.
   */
  deposit(x: number, amount: number): void {
    const c = this.cellAt(x);
    const h = this.heights;
    const spread = [0.2, 0.6, 0.2];
    for (let k = -1; k <= 1; k++) {
      const i = c + k;
      if (i < 0 || i >= h.length) continue;
      const fill = h[i]! / MAX_HEIGHT;
      const ease = Math.max(0, 1 - fill * fill * fill);
      h[i] = Math.min(MAX_HEIGHT, h[i]! + amount * spread[k + 1]! * ease);
    }
  }

  /**
   * Removes up to `fraction` of the snow within `radius` of x, weighted by
   * distance. Returns the amount removed.
   */
  take(x: number, radius: number, fraction: number): number {
    const h = this.heights;
    const from = this.cellAt(x - radius);
    const to = this.cellAt(x + radius);
    let removed = 0;
    for (let i = from; i <= to; i++) {
      const cx = (i + 0.5) * CELL;
      const d = Math.abs(cx - x) / radius;
      if (d > 1) continue;
      const w = fraction * (1 - d * d);
      const dh = h[i]! * w;
      h[i] = h[i]! - dh;
      removed += dh;
    }
    return removed;
  }

  /** Removes a uniform fraction of all snow. Returns the amount removed. */
  shed(fraction: number): number {
    const h = this.heights;
    let removed = 0;
    for (let i = 0; i < h.length; i++) {
      const dh = h[i]! * fraction;
      h[i] = h[i]! - dh;
      removed += dh;
    }
    return removed;
  }

  clear(): number {
    const total = this.total();
    this.heights.fill(0);
    return total;
  }

  total(): number {
    let sum = 0;
    for (const v of this.heights) sum += v;
    return sum;
  }

  peak(): number {
    let max = 0;
    for (const v of this.heights) if (v > max) max = v;
    return max;
  }

  /**
   * Angle-of-repose relaxation plus a little diffusion for soft, rounded banks.
   * Snow pushed past either end is returned as spills so the caller can turn
   * it into falling clumps. `wind` (-1..1) nudges snow downwind.
   */
  relax(dt: number, wind: number, spills: Spill[]): void {
    const h = this.heights;
    const n = h.length;
    const limit = REPOSE_SLOPE * CELL;
    const rate = Math.min(1, dt * 14);

    for (let pass = 0; pass < 2; pass++) {
      for (let i = 0; i < n - 1; i++) {
        const d = h[i]! - h[i + 1]!;
        const excess = Math.abs(d) - limit;
        if (excess <= 0) continue;
        const move = excess * 0.5 * rate;
        if (d > 0) {
          h[i] = h[i]! - move;
          h[i + 1] = h[i + 1]! + move;
        } else {
          h[i] = h[i]! + move;
          h[i + 1] = h[i + 1]! - move;
        }
      }
    }

    // Gentle diffusion rounds off the ridges left by individual flakes.
    const s = this.scratch;
    const k = Math.min(0.25, dt * 1.6);
    for (let i = 0; i < n; i++) {
      const l = h[i > 0 ? i - 1 : i]!;
      const r = h[i < n - 1 ? i + 1 : i]!;
      s[i] = h[i]! + k * (l + r - 2 * h[i]!);
    }
    h.set(s);

    // Wind slowly erodes the windward side and builds up the lee side.
    if (wind !== 0) {
      const w = Math.min(0.5, Math.abs(wind) * dt * 2);
      if (wind > 0) {
        for (let i = n - 1; i > 0; i--) {
          const m = h[i - 1]! * w * 0.08;
          h[i - 1] = h[i - 1]! - m;
          h[i] = h[i]! + m;
        }
      } else {
        for (let i = 0; i < n - 1; i++) {
          const m = h[i + 1]! * w * 0.08;
          h[i + 1] = h[i + 1]! - m;
          h[i] = h[i]! + m;
        }
      }
    }

    // Edges: snow can only overhang so far before it tumbles off.
    const edgeLimit = EDGE_SLOPE * CELL * 2;
    for (const [i, x] of [
      [0, 0],
      [n - 1, this.width],
    ] as const) {
      const over = h[i]! - edgeLimit;
      if (over > 0.01) {
        const amount = over * rate;
        h[i] = h[i]! - amount;
        spills.push({ x, amount });
      }
    }

    for (let i = 0; i < n; i++) if (h[i]! < 0.001) h[i] = 0;
  }
}
