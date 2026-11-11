/**
 * Snow world for the landing demo: falling particles, a fake desktop with
 * windows and a Dock, and drifts on their top edges. Units are CSS pixels,
 * y grows downwards. Rendering and input live in their own modules.
 */
import { Drift, CELL, type Spill } from './drift';
import { Yard } from './snowman';

export type Intensity = 'light' | 'steady' | 'blizzard';
export type Tool = 'mitten' | 'shovel';
export type WindDir = -1 | 0 | 1;

export interface Surface {
  id: number;
  kind: 'window' | 'dock';
  /** What the fake window shows inside. */
  content: 'notes' | 'photos' | 'dock';
  title: string;
  x: number;
  y: number;
  w: number;
  h: number;
  /** Smoothed velocity while dragged, px/s. */
  vx: number;
  vy: number;
  /** Smoothed speed regardless of direction, so jiggling also shakes snow off. */
  shake: number;
  drift: Drift;
  /** Accumulated snow spilled over the left/right ends, turned into clumps. */
  spillLeft: number;
  spillRight: number;
}

export const TITLE_BAR = 26;
export const MENU_BAR = 22;

/** Particle kinds. */
export const FLAKE = 0;
export const CLUMP = 1;
export const PUFF = 2;

const MAX_PARTICLES = 1600;
const GRAVITY = 900;

/** Most snow the shovel carries, in drift units (px of height summed over cells). */
export const SHOVEL_CAPACITY = 520;
/** Half the shovel blade width, px. */
export const SHOVEL_HALF_WIDTH = 14;
const HEAP_GRAVITY = 1000;
const HEAP_MAX_FALL = 900;
const HEAP_MAX_THROW = 900;

/** A shovel load thrown as one lump; lands as a pile or bursts at the bottom. */
export interface Heap {
  x: number;
  y: number;
  vx: number;
  vy: number;
  amount: number;
  r: number;
  rot: number;
  spin: number;
  /** Fixed per heap so its lumps keep their shape in flight. */
  seed: number;
}

/** Visual radius of a thrown load, px. */
export const heapRadius = (amount: number): number => Math.min(16, 3 + Math.sqrt(Math.max(0, amount)) * 0.55);

const INTENSITY: Record<Intensity, { count: number; speed: number; wind: number }> = {
  light: { count: 110, speed: 0.8, wind: 55 },
  steady: { count: 260, speed: 1, wind: 75 },
  blizzard: { count: 640, speed: 1.45, wind: 150 },
};

const rand = (a: number, b: number): number => a + Math.random() * (b - a);

export class World {
  width = 0;
  height = 0;
  time = 0;

  intensity: Intensity = 'steady';
  windDir: WindDir = 0;
  /** Current horizontal wind, px/s (eases towards the target). */
  wind = 0;
  tool: Tool = 'mitten';
  /** Multiplier applied to the particle budget (lower for reduced motion). */
  density = 1;

  readonly windows: Surface[] = [];
  dock!: Surface;
  /** Snowballs and snowmen. */
  readonly yard = new Yard(this);
  /** Snow riding on the shovel blade. */
  shovelLoad = 0;
  /** Thrown shovel loads in flight. */
  readonly heaps: Heap[] = [];

  // Particle storage, struct-of-arrays.
  count = 0;
  readonly px = new Float32Array(MAX_PARTICLES);
  readonly py = new Float32Array(MAX_PARTICLES);
  readonly pvx = new Float32Array(MAX_PARTICLES);
  readonly pvy = new Float32Array(MAX_PARTICLES);
  readonly pr = new Float32Array(MAX_PARTICLES);
  readonly pmass = new Float32Array(MAX_PARTICLES);
  readonly pphase = new Float32Array(MAX_PARTICLES);
  readonly plife = new Float32Array(MAX_PARTICLES);
  readonly pkind = new Uint8Array(MAX_PARTICLES);

  private flakeCount = 0;
  private readonly spills: Spill[] = [];
  private nextId = 1;

  /** Surfaces in paint order, back to front. The Dock is always on top. */
  get surfaces(): Surface[] {
    return [...this.windows, this.dock];
  }

  private makeSurface(kind: Surface['kind'], content: Surface['content'], title: string): Surface {
    return {
      id: this.nextId++,
      kind,
      content,
      title,
      x: 0,
      y: 0,
      w: 100,
      h: 100,
      vx: 0,
      vy: 0,
      shake: 0,
      drift: new Drift(100),
      spillLeft: 0,
      spillRight: 0,
    };
  }

  resize(width: number, height: number): void {
    const first = this.width === 0;
    const sx = first ? 1 : width / this.width;
    const sy = first ? 1 : height / this.height;
    this.width = width;
    this.height = height;

    if (first) {
      this.windows.push(this.makeSurface('window', 'notes', 'Зимние планы'));
      this.windows.push(this.makeSurface('window', 'photos', 'Фото — Каникулы'));
      this.dock = this.makeSurface('dock', 'dock', 'Dock');
    }

    const [a, b] = this.windows as [Surface, Surface];
    const layout = (s: Surface, w: number, h: number, x: number, y: number): void => {
      s.w = Math.round(w);
      s.h = Math.round(h);
      s.x = first ? Math.round(x) : s.x * sx;
      s.y = first ? Math.round(y) : s.y * sy;
      s.drift.resize(s.w);
      this.clampSurface(s);
    };
    const clampN = (v: number, lo: number, hi: number): number => Math.min(hi, Math.max(lo, v));

    const aw = clampN(width * 0.42, 150, 380);
    const bw = clampN(width * 0.38, 140, 340);
    layout(a, aw, clampN(height * 0.44, 130, 250), width * 0.07, height * 0.2);
    layout(b, bw, clampN(height * 0.4, 120, 230), width - bw - width * 0.07, height * 0.36);

    const dockH = clampN(height * 0.1, 40, 56);
    const dockW = Math.min(width * 0.66, 470);
    const dock = this.dock;
    dock.w = Math.round(dockW);
    dock.h = Math.round(dockH);
    dock.x = Math.round((width - dockW) / 2);
    dock.y = Math.round(height - dockH - 8);
    dock.drift.resize(dock.w);

    if (first) {
      this.seedDrifts();
      this.prefill();
    }
  }

  /** A little snow is already lying when the demo opens. */
  private seedDrifts(): void {
    for (const s of this.surfaces) {
      const h = s.drift.heights;
      const n = h.length;
      const peak = s.kind === 'dock' ? 9 : rand(12, 18);
      for (let i = 0; i < n; i++) {
        const t = i / (n - 1);
        const bump = Math.sin(Math.PI * t) ** 0.7;
        h[i] = peak * bump * (0.85 + 0.15 * Math.sin(i * 0.21 + s.id));
      }
    }
  }

  /** Fill the sky so the first frame already has snow in the air. */
  private prefill(): void {
    const target = this.targetFlakes();
    while (this.flakeCount < target) this.spawnFlake(rand(-10, this.height));
  }

  targetFlakes(): number {
    const area = (this.width * this.height) / (900 * 520);
    const scale = Math.min(1.4, Math.max(0.35, area));
    return Math.min(MAX_PARTICLES - 300, Math.round(INTENSITY[this.intensity].count * scale * this.density));
  }

  clampSurface(s: Surface): void {
    s.x = Math.min(this.width - s.w * 0.35, Math.max(-s.w * 0.65, s.x));
    s.y = Math.min(this.height - TITLE_BAR - 10, Math.max(MENU_BAR + 2, s.y));
  }

  /** Topmost window whose title bar contains the point. */
  titleBarAt(x: number, y: number): Surface | null {
    for (let i = this.windows.length - 1; i >= 0; i--) {
      const s = this.windows[i]!;
      if (x >= s.x && x <= s.x + s.w && y >= s.y && y <= s.y + TITLE_BAR) {
        return this.isCovered(s, x, y) ? null : s;
      }
    }
    return null;
  }

  /** Topmost window containing the point. */
  windowAt(x: number, y: number): Surface | null {
    for (let i = this.windows.length - 1; i >= 0; i--) {
      const s = this.windows[i]!;
      if (x >= s.x && x <= s.x + s.w && y >= s.y && y <= s.y + s.h) return s;
    }
    return null;
  }

  bringToFront(s: Surface): void {
    const i = this.windows.indexOf(s);
    if (i < 0 || i === this.windows.length - 1) return;
    this.windows.splice(i, 1);
    this.windows.push(s);
  }

  /** True if a point on `s` is hidden by something painted above it. */
  isCovered(s: Surface, x: number, y: number): boolean {
    const list = this.surfaces;
    for (let i = list.indexOf(s) + 1; i < list.length; i++) {
      const o = list[i]!;
      if (x >= o.x && x <= o.x + o.w && y >= o.y - 1 && y <= o.y + o.h) return true;
    }
    return false;
  }

  moveSurface(s: Surface, x: number, y: number, dt: number): void {
    const ox = s.x;
    const oy = s.y;
    s.x = x;
    s.y = y;
    this.clampSurface(s);
    if (dt > 0) {
      const k = 0.45;
      s.vx += ((s.x - ox) / dt - s.vx) * k;
      s.vy += ((s.y - oy) / dt - s.vy) * k;
      s.shake += (Math.hypot(s.x - ox, s.y - oy) / dt - s.shake) * k;
    }
  }

  // ---------------------------------------------------------------- particles

  private add(kind: number, x: number, y: number, vx: number, vy: number, r: number, mass: number): number {
    if (this.count >= MAX_PARTICLES) return -1;
    const i = this.count++;
    this.px[i] = x;
    this.py[i] = y;
    this.pvx[i] = vx;
    this.pvy[i] = vy;
    this.pr[i] = r;
    this.pmass[i] = mass;
    this.pphase[i] = Math.random() * Math.PI * 2;
    this.plife[i] = kind === PUFF ? rand(0.6, 1.3) : 0;
    this.pkind[i] = kind;
    if (kind === FLAKE) this.flakeCount++;
    return i;
  }

  private remove(i: number): void {
    if (this.pkind[i] === FLAKE) this.flakeCount--;
    const last = --this.count;
    if (i === last) return;
    this.px[i] = this.px[last]!;
    this.py[i] = this.py[last]!;
    this.pvx[i] = this.pvx[last]!;
    this.pvy[i] = this.pvy[last]!;
    this.pr[i] = this.pr[last]!;
    this.pmass[i] = this.pmass[last]!;
    this.pphase[i] = this.pphase[last]!;
    this.plife[i] = this.plife[last]!;
    this.pkind[i] = this.pkind[last]!;
  }

  private spawnFlake(y = rand(-24, -4)): void {
    const cfg = INTENSITY[this.intensity];
    const margin = Math.abs(this.wind) * 4 + 20;
    const x = rand(-margin, this.width + margin);
    // Bigger flakes are rarer, closer and faster.
    const r = 0.8 + Math.random() ** 2.2 * 2.6;
    const vy = (26 + r * 17) * cfg.speed * rand(0.85, 1.15);
    this.add(FLAKE, x, y, this.wind, vy, r, r * r * 0.5);
  }

  /** A lump of snow falling under gravity that lands back as snow. */
  spawnClump(x: number, y: number, vx: number, vy: number, mass: number): void {
    const r = Math.min(3.4, 1.3 + Math.sqrt(mass) * 0.6);
    this.add(CLUMP, x, y, vx, vy, r, mass);
  }

  /** Cosmetic powder that fades out and never lands. */
  spawnPuff(x: number, y: number, vx: number, vy: number): void {
    this.add(PUFF, x, y, vx, vy, rand(0.8, 2.2), 0);
  }

  // ------------------------------------------------------------------- tools

  /** Mitten: brush snow away around the cursor, flicking it in the stroke direction. */
  sweep(x: number, y: number, vx: number, vy: number, dt: number): void {
    const radius = 24;
    for (const s of this.surfaces) {
      const local = x - s.x;
      if (local < -radius || local > s.w + radius) continue;
      const top = s.y - s.drift.heightAt(Math.min(s.w, Math.max(0, local)));
      if (y < top - radius || y > s.y + radius * 0.6) continue;
      if (this.isCovered(s, Math.min(s.x + s.w, Math.max(s.x, x)), s.y)) continue;

      const removed = s.drift.take(local, radius, Math.min(0.9, dt * 16));
      if (removed <= 0.05) continue;
      const pieces = Math.min(14, Math.ceil(removed / 1.6));
      for (let k = 0; k < pieces; k++) {
        const lx = Math.min(s.w, Math.max(0, local + rand(-radius, radius) * 0.7));
        const sy = s.y - s.drift.heightAt(lx) - rand(0, 4);
        this.spawnClump(
          s.x + lx,
          sy,
          vx * rand(0.25, 0.55) + rand(-40, 40),
          Math.min(0, vy * 0.3) - rand(60, 180),
          removed / pieces,
        );
      }
    }

    // Push nearby airborne flakes along with the stroke.
    const r2 = (radius * 1.8) ** 2;
    for (let i = 0; i < this.count; i++) {
      const dx = this.px[i]! - x;
      const dy = this.py[i]! - y;
      if (dx * dx + dy * dy > r2) continue;
      this.pvx[i] = this.pvx[i]! + vx * 0.08;
      if (this.pkind[i] !== FLAKE) this.pvy[i] = this.pvy[i]! + vy * 0.08;
    }
  }

  /**
   * Front-most surface whose drift is under (x, y), within `tolerance` px of
   * its top. A point inside a window body blocks the windows behind it.
   */
  driftAt(x: number, y: number, tolerance = 12): Surface | null {
    const list = this.surfaces;
    for (let k = list.length - 1; k >= 0; k--) {
      const s = list[k]!;
      const local = x - s.x;
      if (local < 0 || local > s.w) continue;
      const height = s.drift.heightAt(local);
      const top = s.y - height;
      if (y >= top - tolerance && y <= s.y + tolerance && height > 0.05) return s;
      if (y > s.y && y < s.y + s.h) return null;
    }
    return null;
  }

  /** Shovel: scrapes up to `depth` px off the drift under the blade onto the shovel. */
  scoop(x: number, y: number, depth: number): number {
    const room = SHOVEL_CAPACITY - this.shovelLoad;
    if (room <= 0.01) return 0;
    const s = this.driftAt(x, y);
    if (!s) return 0;
    const taken = s.drift.scrape(x - s.x, SHOVEL_HALF_WIDTH, depth, room);
    this.shovelLoad = Math.min(SHOVEL_CAPACITY, this.shovelLoad + taken);
    // A little powder kicked up by the blade; cosmetic, carries no snow.
    if (taken > 0.5 && Math.random() < Math.min(1, taken / 6)) {
      this.spawnPuff(x + rand(-SHOVEL_HALF_WIDTH, SHOVEL_HALF_WIDTH), y - rand(2, 8), rand(-50, 50), rand(-120, -40));
    }
    return taken;
  }

  /** Throws the whole shovel load from (x, y) as one clump. */
  dump(x: number, y: number, vx: number, vy: number): Heap | null {
    const amount = this.shovelLoad;
    this.shovelLoad = 0;
    if (amount <= 0.01 || !Number.isFinite(x) || !Number.isFinite(y)) return null;

    let tvx = Number.isFinite(vx) ? vx * 0.6 : 0;
    let tvy = Number.isFinite(vy) ? vy * 0.6 : 0;
    const speed = Math.hypot(tvx, tvy);
    if (speed > HEAP_MAX_THROW) {
      tvx *= HEAP_MAX_THROW / speed;
      tvy *= HEAP_MAX_THROW / speed;
    }

    // Dumped right onto a bank: start just above its top so it lands there.
    const r = heapRadius(amount);
    let cy = y;
    const list = this.surfaces;
    for (let k = list.length - 1; k >= 0; k--) {
      const s = list[k]!;
      if (x < s.x || x > s.x + s.w) continue;
      const top = s.y - s.drift.heightAt(x - s.x);
      if (y >= top - r && y <= s.y + 12) {
        cy = Math.min(y, top - r * 0.6 - 0.5);
        break;
      }
      if (y > s.y && y < s.y + s.h) break;
    }

    const heap: Heap = {
      x,
      y: cy,
      vx: tvx,
      vy: tvy,
      amount,
      r,
      rot: Math.random() * Math.PI * 2,
      spin: rand(-3, 3),
      seed: Math.floor(Math.random() * 1e9),
    };
    this.heaps.push(heap);
    return heap;
  }

  /** Total snow lying in drifts, on the shovel and in flight as heaps. */
  snowTotal(): number {
    let sum = this.shovelLoad;
    for (const s of this.surfaces) sum += s.drift.total();
    for (const h of this.heaps) sum += h.amount;
    return sum;
  }

  /** «Очистить»: wipes every drift, snowball and shovel load at once. */
  clearAll(): void {
    for (const s of this.surfaces) {
      const h = s.drift.heights;
      // Roughly one puff of powder per 40 units of snow, at most ~90 per surface.
      const step = Math.max(40, s.drift.total() / 90);
      let budget = 0;
      for (let i = 0; i < h.length; i++) {
        budget += h[i]!;
        if (budget < step) continue;
        budget -= step;
        const x = s.x + (i + 0.5) * CELL;
        this.spawnPuff(x, s.y - h[i]! * Math.random(), rand(-120, 120), rand(-320, -80));
      }
      s.drift.clear();
      s.spillLeft = 0;
      s.spillRight = 0;
    }
    for (const heap of this.heaps) {
      for (let k = 0; k < 8; k++) this.spawnPuff(heap.x, heap.y, rand(-120, 120), rand(-260, -60));
    }
    this.heaps.length = 0;
    this.shovelLoad = 0;
    this.yard.clear();
  }

  // -------------------------------------------------------------------- step

  step(dt: number): void {
    this.time += dt;
    const cfg = INTENSITY[this.intensity];
    const target = this.windDir * cfg.wind;
    this.wind += (target - this.wind) * Math.min(1, dt * 1.2);
    const gust = 1 + 0.25 * Math.sin(this.time * 0.7) + 0.12 * Math.sin(this.time * 2.3 + 1);
    const windNow = this.wind * gust;

    this.updateSurfaces(dt);
    this.updateParticles(dt, windNow);
    this.updateHeaps(dt);
    this.yard.step(dt);

    // Top up the snowfall gradually so intensity changes ease in.
    const want = this.targetFlakes();
    let budget = Math.ceil(want * dt * 0.8) + 1;
    while (this.flakeCount < want && budget-- > 0) this.spawnFlake();
  }

  private updateSurfaces(dt: number): void {
    const windNorm = this.wind / 150;
    for (const s of this.surfaces) {
      // Shake snow off a window that is moved briskly.
      if (s.shake > 650) {
        const rate = Math.min(7, (s.shake - 650) / 700);
        const frac = 1 - Math.exp(-rate * dt);
        this.shakeOff(s, frac);
        if (s.shake > 1500) this.yard.topple(s);
      }
      const damp = Math.exp(-dt * 10);
      s.vx *= damp;
      s.vy *= damp;
      s.shake *= damp;

      this.spills.length = 0;
      s.drift.relax(dt, windNorm, this.spills);
      for (const sp of this.spills) {
        if (sp.x <= 0) s.spillLeft += sp.amount;
        else s.spillRight += sp.amount;
      }
      while (s.spillLeft > 2.5) {
        s.spillLeft -= 2.5;
        this.spawnClump(s.x - 1, s.y - 2, rand(-30, -5) + this.wind * 0.3, rand(-10, 20), 2.5);
      }
      while (s.spillRight > 2.5) {
        s.spillRight -= 2.5;
        this.spawnClump(s.x + s.w + 1, s.y - 2, rand(5, 30) + this.wind * 0.3, rand(-10, 20), 2.5);
      }
    }
  }

  private updateHeaps(dt: number): void {
    const heaps = this.heaps;
    for (let i = 0; i < heaps.length; i++) {
      const c = heaps[i]!;
      const prevBottom = c.y + c.r * 0.6;
      c.vy = Math.min(HEAP_MAX_FALL, c.vy + HEAP_GRAVITY * dt);
      c.vx *= Math.exp(-0.6 * dt);
      c.x += c.vx * dt;
      c.y += c.vy * dt;
      c.rot += c.spin * dt;

      let gone = c.vy > 0 && this.landHeap(c, prevBottom);
      if (!gone && c.y + c.r * 0.6 >= this.height) {
        this.burst(c.amount, c.x, Math.min(c.y, this.height - c.r * 0.5), c.r);
        gone = true;
      }
      if (!gone && (c.x < -300 || c.x > this.width + 300)) gone = true;
      if (gone) heaps.splice(i--, 1);
    }
  }

  /** Adds the heap to the front-most drift it crosses as a tall pile. */
  private landHeap(c: Heap, prevBottom: number): boolean {
    const bottom = c.y + c.r * 0.6;
    const list = this.surfaces;
    for (let k = list.length - 1; k >= 0; k--) {
      const s = list[k]!;
      if (c.x < s.x || c.x > s.x + s.w) continue;
      const local = c.x - s.x;
      const top = s.y - s.drift.heightAt(local);
      if (prevBottom <= top + 6 && bottom >= top) {
        const accepted = s.drift.depositPile(local, c.amount);
        const rest = c.amount - accepted;
        // The drift is full there: the rest slides off as loose snow.
        if (rest > 0.5) this.burst(rest, c.x, top - 2, c.r);
        for (let p = 0; p < 6; p++) this.spawnPuff(c.x + rand(-c.r, c.r), top - rand(0, 4), rand(-90, 90), rand(-160, -40));
        return true;
      }
      // Behind this window: surfaces further back are out of reach.
      if (c.y > s.y && c.y < s.y + s.h) return false;
    }
    return false;
  }

  /** Breaks `amount` of snow into loose clumps and powder around (x, y). */
  private burst(amount: number, x: number, y: number, r: number): void {
    const spread = Math.max(2, r * 0.7);
    const pieces = Math.max(1, Math.min(40, Math.ceil(amount / 2.5)));
    for (let k = 0; k < pieces; k++) {
      this.spawnClump(x + rand(-spread, spread), y + rand(-spread, spread) * 0.5, rand(-160, 160), -rand(60, 260), amount / pieces);
    }
    for (let k = 0; k < 10; k++) this.spawnPuff(x + rand(-spread, spread), y, rand(-140, 140), -rand(80, 300));
  }

  private shakeOff(s: Surface, frac: number): void {
    const h = s.drift.heights;
    let acc = 0;
    let spawned = 0;
    for (let i = 0; i < h.length; i++) {
      const dh = h[i]! * frac;
      h[i] = h[i]! - dh;
      acc += dh;
      if (acc > 2.2 && spawned < 70) {
        acc -= 2.2;
        spawned++;
        // Snow keeps only part of the window's motion, so it lags and slides off.
        this.spawnClump(
          s.x + (i + 0.5) * CELL,
          s.y - h[i]! - rand(0, 3),
          s.vx * rand(0.2, 0.5) + rand(-30, 30),
          s.vy * rand(0.2, 0.5) - rand(0, 80),
          2.2,
        );
      }
    }
  }

  private updateParticles(dt: number, windNow: number): void {
    const surfaces = this.surfaces;
    const bottom = this.height + 12;
    const margin = Math.abs(this.wind) * 4 + 60;
    const want = this.targetFlakes();

    for (let i = 0; i < this.count; i++) {
      const kind = this.pkind[i]!;
      const ox = this.px[i]!;
      const oy = this.py[i]!;
      let vx = this.pvx[i]!;
      let vy = this.pvy[i]!;

      if (kind === FLAKE) {
        const r = this.pr[i]!;
        // Small flakes follow the wind more eagerly.
        vx += (windNow * (0.7 + 0.5 / r) - vx) * Math.min(1, dt * 1.5);
        const phase = (this.pphase[i] = this.pphase[i]! + dt * (1.2 + r * 0.3));
        this.px[i] = ox + (vx + Math.sin(phase) * (10 + r * 4)) * dt;
        this.py[i] = oy + vy * dt;
      } else {
        vy = Math.min(650, vy + GRAVITY * dt * (kind === PUFF ? 0.45 : 1));
        vx += (windNow * 0.4 - vx) * Math.min(1, dt * (kind === PUFF ? 2.5 : 0.9));
        this.px[i] = ox + vx * dt;
        this.py[i] = oy + vy * dt;
        if (kind === PUFF) {
          this.plife[i] = this.plife[i]! - dt;
          if (this.plife[i]! <= 0) {
            this.remove(i--);
            continue;
          }
        }
      }
      this.pvx[i] = vx;
      this.pvy[i] = vy;

      const x = this.px[i]!;
      const y = this.py[i]!;

      if (kind !== PUFF && vy > 0 && this.tryLand(i, surfaces, x, oy, y)) {
        if (kind === FLAKE && this.flakeCount <= want) {
          this.recycleFlake(i);
        } else {
          this.remove(i--);
        }
        continue;
      }

      if (y > bottom || x < -margin || x > this.width + margin) {
        if (kind === FLAKE && this.flakeCount <= want) this.recycleFlake(i);
        else this.remove(i--);
      }
    }
  }

  private recycleFlake(i: number): void {
    const margin = Math.abs(this.wind) * 4 + 20;
    this.px[i] = rand(-margin, this.width + margin);
    this.py[i] = rand(-24, -4);
    this.pvx[i] = this.wind;
  }

  /** Lands particle i on the first exposed drift it crossed this step. */
  private tryLand(i: number, surfaces: Surface[], x: number, oy: number, y: number): boolean {
    for (let k = surfaces.length - 1; k >= 0; k--) {
      const s = surfaces[k]!;
      const local = x - s.x;
      if (local < 0 || local > s.w) continue;
      const top = s.y - s.drift.heightAt(local);
      if (oy > top + 2 || y < top) continue;
      if (this.isCovered(s, x, s.y)) continue;
      s.drift.deposit(local, this.pmass[i]!);
      return true;
    }
    return false;
  }
}
