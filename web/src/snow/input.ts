/** Pointer and keyboard handling for the snow demo canvas. */
import type { ViewState } from './render';
import type { Ball } from './snowman';
import type { Intensity, Surface, WindDir, World } from './world';

export interface InputCallbacks {
  onWind(dir: WindDir): void;
  onIntensity(level: Intensity): void;
}

type Mode =
  | { kind: 'idle' }
  | { kind: 'drag'; surface: Surface; offX: number; offY: number; t: number }
  | { kind: 'mitten' }
  | { kind: 'ball'; ball: Ball }
  /** Touch press waiting to become either a sweep or a snowball. */
  | { kind: 'pending'; x: number; y: number; timer: number };

/** Hold time on a drift before a touch starts a snowball, ms. */
const LONG_PRESS = 380;

const LEVELS: Intensity[] = ['light', 'steady', 'blizzard'];

export class Input {
  readonly view: ViewState = {
    pointerX: 0,
    pointerY: 0,
    pointerInside: false,
    pointerDown: false,
    showMitten: false,
  };

  /** Whether the simulation is running; tools do nothing while paused. */
  running = true;

  private mode: Mode = { kind: 'idle' };
  private velX = 0;
  private velY = 0;
  private lastMoveT = 0;
  private pointerType = 'mouse';
  private readonly abort = new AbortController();

  constructor(
    private readonly canvas: HTMLCanvasElement,
    private readonly world: World,
    private readonly cb: InputCallbacks,
  ) {
    const opts = { signal: this.abort.signal };
    canvas.addEventListener('pointerdown', (e) => this.down(e), opts);
    canvas.addEventListener('pointermove', (e) => this.move(e), opts);
    canvas.addEventListener('pointerup', (e) => this.up(e), opts);
    canvas.addEventListener('pointercancel', (e) => this.up(e), opts);
    canvas.addEventListener('pointerleave', () => this.leave(), opts);
    canvas.addEventListener('keydown', (e) => this.key(e), opts);
    canvas.addEventListener('contextmenu', (e) => e.preventDefault(), opts);
  }

  dispose(): void {
    this.abort.abort();
  }

  private local(e: PointerEvent): [number, number] {
    const r = this.canvas.getBoundingClientRect();
    return [e.clientX - r.left, e.clientY - r.top];
  }

  private down(e: PointerEvent): void {
    if (e.button !== 0) return;
    this.pointerType = e.pointerType;
    const [x, y] = this.local(e);
    this.trackPointer(x, y, e.timeStamp, true);
    this.view.pointerDown = true;
    this.canvas.focus({ preventScroll: true });
    this.canvas.setPointerCapture(e.pointerId);
    e.preventDefault();

    const bar = this.world.titleBarAt(x, y);
    if (bar) {
      this.world.bringToFront(bar);
      bar.vx = 0;
      bar.vy = 0;
      this.mode = { kind: 'drag', surface: bar, offX: x - bar.x, offY: y - bar.y, t: e.timeStamp };
      this.updateCursor(x, y);
      return;
    }

    const win = this.world.windowAt(x, y);
    if (win) this.world.bringToFront(win);

    if (e.altKey && this.running && this.startBall(x, y)) {
      this.updateCursor(x, y);
      return;
    }

    if (this.world.tool === 'shovel') {
      if (this.running) this.world.shovel();
    } else if (e.pointerType !== 'mouse' && this.running) {
      const timer = window.setTimeout(() => {
        if (this.mode.kind !== 'pending') return;
        if (!this.startBall(this.mode.x, this.mode.y)) this.mode = { kind: 'mitten' };
      }, LONG_PRESS);
      this.mode = { kind: 'pending', x, y, timer };
    } else {
      this.mode = { kind: 'mitten' };
    }
    this.updateCursor(x, y);
  }

  private startBall(x: number, y: number): boolean {
    const ball = this.world.yard.start(x, y);
    if (!ball) return false;
    this.mode = { kind: 'ball', ball };
    return true;
  }

  private move(e: PointerEvent): void {
    this.pointerType = e.pointerType;
    const [x, y] = this.local(e);
    this.trackPointer(x, y, e.timeStamp, false);
    const m = this.mode;
    if (m.kind === 'drag') {
      const dt = Math.max(0.001, (e.timeStamp - m.t) / 1000);
      m.t = e.timeStamp;
      this.world.moveSurface(m.surface, x - m.offX, y - m.offY, dt);
    } else if (m.kind === 'ball') {
      this.world.yard.roll(m.ball, x, y);
    } else if (m.kind === 'pending' && Math.hypot(x - m.x, y - m.y) > 8) {
      window.clearTimeout(m.timer);
      this.mode = { kind: 'mitten' };
    }
    this.updateCursor(x, y);
  }

  private up(e: PointerEvent): void {
    if (this.canvas.hasPointerCapture(e.pointerId)) this.canvas.releasePointerCapture(e.pointerId);
    const m = this.mode;
    if (m.kind === 'ball') this.world.yard.release(m.ball, this.velX, this.velY);
    if (m.kind === 'pending') window.clearTimeout(m.timer);
    this.mode = { kind: 'idle' };
    this.view.pointerDown = false;
    if (e.pointerType !== 'mouse') this.view.pointerInside = false;
    const [x, y] = this.local(e);
    this.updateCursor(x, y);
  }

  private leave(): void {
    if (this.mode.kind === 'idle') this.view.pointerInside = false;
  }

  private trackPointer(x: number, y: number, t: number, reset: boolean): void {
    const dt = (t - this.lastMoveT) / 1000;
    if (!reset && dt > 0 && dt < 0.2) {
      const k = 0.5;
      this.velX += ((x - this.view.pointerX) / dt - this.velX) * k;
      this.velY += ((y - this.view.pointerY) / dt - this.velY) * k;
    } else {
      this.velX = 0;
      this.velY = 0;
    }
    this.lastMoveT = t;
    this.view.pointerX = x;
    this.view.pointerY = y;
    this.view.pointerInside = true;
  }

  private updateCursor(x: number, y: number): void {
    const mitten = this.world.tool === 'mitten';
    let cursor = 'default';
    if (this.mode.kind === 'drag' || this.mode.kind === 'ball') cursor = 'grabbing';
    else if (this.world.titleBarAt(x, y)) cursor = 'grab';
    else if (mitten) cursor = this.pointerType === 'mouse' ? 'none' : 'default';
    else cursor = 'pointer';
    this.canvas.style.cursor = cursor;
    this.view.showMitten = mitten && (cursor === 'none' || this.mode.kind === 'mitten');
  }

  /** Called every animation frame. */
  update(dt: number): void {
    if (this.mode.kind === 'mitten' && this.running) {
      this.world.sweep(this.view.pointerX, this.view.pointerY, this.velX, this.velY, dt);
    }
    // Pointer velocity fades when the pointer stops moving.
    const decay = Math.exp(-dt * 8);
    this.velX *= decay;
    this.velY *= decay;
  }

  private key(e: KeyboardEvent): void {
    const w = this.world;
    let handled = true;
    switch (e.key) {
      case 'ArrowLeft':
        this.cb.onWind(Math.max(-1, w.windDir - 1) as WindDir);
        break;
      case 'ArrowRight':
        this.cb.onWind(Math.min(1, w.windDir + 1) as WindDir);
        break;
      case ' ':
      case 'Spacebar':
        this.cb.onWind(0);
        break;
      case 'ArrowUp':
      case 'ArrowDown': {
        const i = LEVELS.indexOf(w.intensity) + (e.key === 'ArrowUp' ? 1 : -1);
        this.cb.onIntensity(LEVELS[Math.min(LEVELS.length - 1, Math.max(0, i))]!);
        break;
      }
      default:
        handled = false;
    }
    if (handled) e.preventDefault();
  }
}
