/**
 * Snowballs rolled out of drifts and the stacks they form on windows.
 * Three balls on top of each other make a snowman.
 */
import type { Surface, World } from './world';

export interface Ball {
  x: number;
  y: number;
  r: number;
  vx: number;
  vy: number;
  /** Rolling angle, radians, used to spin the texture. */
  angle: number;
  /** Drift the ball is being rolled along, if any. */
  surface: Surface | null;
  falling: boolean;
}

export interface Stack {
  surface: Surface;
  /** Local x on the surface. */
  x: number;
  /** Radii from the bottom up. */
  radii: number[];
  angles: number[];
}

export const SNOWMAN_BALLS = 3;
const MIN_R = 4;
const MAX_R = 26;
const GRAVITY = 1100;
const MAX_STACKS = 8;
/** How much of the snowball sinks into the drift it rests on. */
const SINK = 0.7;

export interface PlacedBall {
  x: number;
  y: number;
  r: number;
  angle: number;
}

export class Yard {
  readonly stacks: Stack[] = [];
  readonly balls: Ball[] = [];

  private readonly world: World;

  constructor(world: World) {
    this.world = world;
  }

  /** Ball positions of a stack in canvas space, bottom first. */
  place(stack: Stack): PlacedBall[] {
    const s = stack.surface;
    const out: PlacedBall[] = [];
    let y = s.y - s.drift.heightAt(stack.x) * SINK;
    stack.radii.forEach((r, i) => {
      const cy = i === 0 ? y - r : y - r * 0.82;
      out.push({ x: s.x + stack.x, y: cy, r, angle: stack.angles[i] ?? 0 });
      y = cy - r * 0.82;
    });
    return out;
  }

  /** Resting height of a ball rolled along a surface's drift. */
  private restY(s: Surface, local: number, r: number): number {
    return s.y - s.drift.heightAt(local) * SINK - r;
  }

  /** Exposed drift close to the point, with enough snow to start a ball. */
  private driftNear(x: number, y: number, minSnow: number): Surface | null {
    const list = this.world.surfaces;
    for (let k = list.length - 1; k >= 0; k--) {
      const s = list[k]!;
      const local = x - s.x;
      if (local < 0 || local > s.w) continue;
      const h = s.drift.heightAt(local);
      const top = s.y - h;
      if (y < top - 26 || y > s.y + 16) continue;
      if (this.world.isCovered(s, x, s.y)) continue;
      if (h >= minSnow) return s;
    }
    return null;
  }

  /** Starts rolling at the point: picks up a stacked ball or packs a new one. */
  start(x: number, y: number): Ball | null {
    for (let i = this.stacks.length - 1; i >= 0; i--) {
      const stack = this.stacks[i]!;
      const placed = this.place(stack);
      const top = placed[placed.length - 1]!;
      if (Math.hypot(x - top.x, y - top.y) > top.r + 6) continue;
      stack.radii.pop();
      stack.angles.pop();
      if (stack.radii.length === 0) this.stacks.splice(i, 1);
      const ball: Ball = { ...top, vx: 0, vy: 0, surface: null, falling: false };
      this.balls.push(ball);
      return ball;
    }

    const s = this.driftNear(x, y, 2);
    if (!s) return null;
    const local = x - s.x;
    const packed = s.drift.take(local, 8, 0.5);
    const r = Math.max(MIN_R, Math.min(8, Math.sqrt(packed * 0.9)));
    const ball: Ball = { x, y: this.restY(s, local, r), r, vx: 0, vy: 0, angle: 0, surface: s, falling: false };
    this.balls.push(ball);
    return ball;
  }

  /** Moves a held ball with the pointer, growing it while it rolls on snow. */
  roll(ball: Ball, x: number, y: number): void {
    let s = ball.surface;
    if (s) {
      const local = x - s.x;
      const onDrift = local >= 0 && local <= s.w && y > s.y - s.drift.heightAt(local) - ball.r * 2 - 30 && y < s.y + 30;
      if (!onDrift) s = null;
    }
    if (!s) s = this.driftNear(x, y, 0.5);
    ball.surface = s;

    if (!s) {
      ball.x = x;
      ball.y = y;
      return;
    }

    const local = Math.min(s.w - 2, Math.max(2, x - s.x));
    const dx = s.x + local - ball.x;
    if (Math.abs(dx) > 0.01 && Math.abs(dx) < 200) {
      // Picking up snow: the rolled distance over the footprint decides how much.
      const share = Math.min(0.6, Math.abs(dx) / (ball.r * 3));
      const taken = s.drift.take(local, ball.r * 0.9, share);
      ball.r = Math.min(MAX_R, Math.sqrt(ball.r * ball.r + taken * 1.1));
      ball.angle += dx / ball.r;
    }
    ball.x = s.x + local;
    ball.y = this.restY(s, local, ball.r);
  }

  release(ball: Ball, vx: number, vy: number): void {
    // Let go right next to a stack: put it on top.
    for (const stack of this.stacks) {
      if (stack.radii.length >= SNOWMAN_BALLS) continue;
      const placed = this.place(stack);
      const top = placed[placed.length - 1]!;
      if (Math.abs(ball.x - top.x) > top.r + ball.r * 0.5) continue;
      if (ball.y > top.y + top.r || ball.y < top.y - top.r - 120) continue;
      this.removeBall(ball);
      this.pushOnto(stack, top, ball);
      return;
    }
    if (ball.surface) {
      // Let go on a drift: it stays where it is.
      this.settle(ball, ball.surface);
      return;
    }
    ball.falling = true;
    ball.vx = vx * 0.35;
    ball.vy = vy * 0.35;
  }

  private settle(ball: Ball, s: Surface): void {
    this.removeBall(ball);
    const local = Math.min(s.w - ball.r * 0.5, Math.max(ball.r * 0.5, ball.x - s.x));
    this.stacks.push({ surface: s, x: local, radii: [ball.r], angles: [ball.angle] });
    while (this.stacks.length > MAX_STACKS) this.stacks.shift();
  }

  /** Upper balls are always a bit smaller, like a proper snowman. */
  private pushOnto(stack: Stack, top: PlacedBall, ball: Ball): void {
    stack.radii.push(Math.max(MIN_R, Math.min(ball.r, top.r * 0.82)));
    stack.angles.push(ball.angle);
  }

  private removeBall(ball: Ball): void {
    const i = this.balls.indexOf(ball);
    if (i >= 0) this.balls.splice(i, 1);
  }

  /** A hard shake knocks stacks off the window. */
  topple(s: Surface): void {
    for (let i = this.stacks.length - 1; i >= 0; i--) {
      const stack = this.stacks[i]!;
      if (stack.surface !== s) continue;
      for (const p of this.place(stack)) {
        this.balls.push({ ...p, vx: s.vx * 0.4 + (Math.random() - 0.5) * 80, vy: s.vy * 0.3 - 60, surface: null, falling: true });
      }
      this.stacks.splice(i, 1);
    }
  }

  clear(): void {
    const all = [...this.balls, ...this.stacks.flatMap((st) => this.place(st))];
    for (const b of all) {
      for (let k = 0; k < Math.ceil(b.r / 2); k++) {
        this.world.spawnPuff(b.x + (Math.random() - 0.5) * b.r, b.y, (Math.random() - 0.5) * 200, -100 - Math.random() * 200);
      }
    }
    this.balls.length = 0;
    this.stacks.length = 0;
  }

  step(dt: number): void {
    for (const stack of this.stacks) {
      stack.x = Math.min(stack.surface.w - 2, Math.max(2, stack.x));
    }

    for (let i = this.balls.length - 1; i >= 0; i--) {
      const b = this.balls[i]!;
      if (!b.falling) continue;
      const oy = b.y;
      b.vy = Math.min(900, b.vy + GRAVITY * dt);
      b.vx *= Math.exp(-dt * 0.8);
      b.x += b.vx * dt;
      b.y += b.vy * dt;
      b.angle += (b.vx * dt) / b.r;
      if (this.land(b, oy)) continue;
      if (b.y - b.r > this.world.height + 20) this.balls.splice(i, 1);
    }
  }

  /** Lands a falling ball on a stack or a surface. */
  private land(b: Ball, oy: number): boolean {
    // Stacks first: dropping a ball on another one builds the snowman.
    for (const stack of this.stacks) {
      if (stack.radii.length >= SNOWMAN_BALLS) continue;
      const placed = this.place(stack);
      const top = placed[placed.length - 1]!;
      if (Math.abs(b.x - top.x) > top.r * 0.9) continue;
      const contact = top.y - top.r * 0.18;
      if (oy + b.r > contact || b.y + b.r < contact) continue;
      if (this.world.isCovered(stack.surface, top.x, stack.surface.y)) continue;
      this.removeBall(b);
      this.pushOnto(stack, top, b);
      return true;
    }

    const list = this.world.surfaces;
    for (let k = list.length - 1; k >= 0; k--) {
      const s = list[k]!;
      const local = b.x - s.x;
      if (local < 0 || local > s.w) continue;
      const rest = this.restY(s, local, b.r);
      if (oy > rest + 2 || b.y < rest) continue;
      if (this.world.isCovered(s, b.x, s.y)) continue;
      b.y = rest;
      this.settle(b, s);
      return true;
    }
    return false;
  }
}
