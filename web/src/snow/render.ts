/** Canvas 2D renderer for the snow demo. */
import { CELL } from './drift';
import { CLUMP, FLAKE, MENU_BAR, PUFF, TITLE_BAR, type Surface, type World } from './world';

export interface ViewState {
  pointerX: number;
  pointerY: number;
  pointerInside: boolean;
  pointerDown: boolean;
  /** Draw the mitten ring under the cursor. */
  showMitten: boolean;
}

const FONT = '-apple-system, BlinkMacSystemFont, "SF Pro Text", "Segoe UI", Roboto, sans-serif';
const MITTEN_RADIUS = 24;

/** Deterministic PRNG so the wallpaper looks the same after a resize. */
function mulberry32(seed: number): () => number {
  let a = seed >>> 0;
  return () => {
    a = (a + 0x6d2b79f5) >>> 0;
    let t = a;
    t = Math.imul(t ^ (t >>> 15), t | 1);
    t ^= t + Math.imul(t ^ (t >>> 7), t | 61);
    return ((t ^ (t >>> 14)) >>> 0) / 4294967296;
  };
}

function roundRect(ctx: CanvasRenderingContext2D, x: number, y: number, w: number, h: number, r: number): void {
  const rr = Math.min(r, w / 2, h / 2);
  ctx.beginPath();
  ctx.moveTo(x + rr, y);
  ctx.arcTo(x + w, y, x + w, y + h, rr);
  ctx.arcTo(x + w, y + h, x, y + h, rr);
  ctx.arcTo(x, y + h, x, y, rr);
  ctx.arcTo(x, y, x + w, y, rr);
  ctx.closePath();
}

export class Renderer {
  private readonly ctx: CanvasRenderingContext2D;
  private width = 0;
  private height = 0;
  private dpr = 1;
  private wallpaper: HTMLCanvasElement | null = null;
  private sprite: HTMLCanvasElement | null = null;

  constructor(private readonly canvas: HTMLCanvasElement) {
    const ctx = canvas.getContext('2d', { alpha: false });
    if (!ctx) throw new Error('Canvas 2D is not available');
    this.ctx = ctx;
  }

  resize(width: number, height: number, dpr: number): void {
    this.width = width;
    this.height = height;
    this.dpr = dpr;
    this.canvas.width = Math.round(width * dpr);
    this.canvas.height = Math.round(height * dpr);
    this.wallpaper = this.paintWallpaper();
    this.sprite = this.paintSprite();
  }

  // ------------------------------------------------------------- static art

  private offscreen(w: number, h: number): [HTMLCanvasElement, CanvasRenderingContext2D] {
    const c = document.createElement('canvas');
    c.width = Math.max(1, Math.round(w * this.dpr));
    c.height = Math.max(1, Math.round(h * this.dpr));
    const ctx = c.getContext('2d')!;
    ctx.scale(this.dpr, this.dpr);
    return [c, ctx];
  }

  private paintSprite(): HTMLCanvasElement {
    const size = 16;
    const [c, ctx] = this.offscreen(size, size);
    const g = ctx.createRadialGradient(size / 2, size / 2, 0, size / 2, size / 2, size / 2);
    g.addColorStop(0, 'rgba(255,255,255,1)');
    g.addColorStop(0.45, 'rgba(255,255,255,0.85)');
    g.addColorStop(1, 'rgba(255,255,255,0)');
    ctx.fillStyle = g;
    ctx.fillRect(0, 0, size, size);
    return c;
  }

  private paintWallpaper(): HTMLCanvasElement {
    const w = this.width;
    const h = this.height;
    const [c, ctx] = this.offscreen(w, h);
    const rnd = mulberry32(2026);

    const sky = ctx.createLinearGradient(0, 0, 0, h);
    sky.addColorStop(0, '#060f2c');
    sky.addColorStop(0.45, '#112660');
    sky.addColorStop(0.8, '#29407f');
    sky.addColorStop(1, '#3d4f8f');
    ctx.fillStyle = sky;
    ctx.fillRect(0, 0, w, h);

    // Aurora ribbons.
    ctx.lineCap = 'round';
    const ribbons = [
      { y: 0.2, amp: 0.06, color: '120, 230, 210', alpha: 0.05 },
      { y: 0.28, amp: 0.05, color: '130, 170, 255', alpha: 0.045 },
    ];
    for (const rb of ribbons) {
      for (let pass = 0; pass < 6; pass++) {
        ctx.strokeStyle = `rgba(${rb.color}, ${rb.alpha})`;
        ctx.lineWidth = 18 + pass * 14;
        ctx.beginPath();
        ctx.moveTo(-20, h * rb.y);
        ctx.bezierCurveTo(w * 0.3, h * (rb.y - rb.amp * 2), w * 0.55, h * (rb.y + rb.amp * 2), w + 20, h * (rb.y - rb.amp));
        ctx.stroke();
      }
    }

    // Stars.
    const stars = Math.round((w * h) / 2600);
    for (let i = 0; i < stars; i++) {
      const x = rnd() * w;
      const y = rnd() * h * 0.6;
      const r = rnd() < 0.08 ? 1.2 : 0.6;
      ctx.fillStyle = `rgba(230, 240, 255, ${0.25 + rnd() * 0.55})`;
      ctx.beginPath();
      ctx.arc(x, y, r, 0, Math.PI * 2);
      ctx.fill();
    }

    // Moon.
    const mx = w * 0.82;
    const my = h * 0.17;
    const glow = ctx.createRadialGradient(mx, my, 0, mx, my, 70);
    glow.addColorStop(0, 'rgba(220, 235, 255, 0.35)');
    glow.addColorStop(1, 'rgba(220, 235, 255, 0)');
    ctx.fillStyle = glow;
    ctx.fillRect(mx - 70, my - 70, 140, 140);
    ctx.fillStyle = '#eef4ff';
    ctx.beginPath();
    ctx.arc(mx, my, 13, 0, Math.PI * 2);
    ctx.fill();

    // Two ranges of snowy hills.
    const hills = (base: number, amp: number, fill: string, cap: string, seed: number): void => {
      const r2 = mulberry32(seed);
      const pts: [number, number][] = [];
      const steps = 9;
      for (let i = 0; i <= steps; i++) {
        pts.push([(i / steps) * (w + 80) - 40, h * (base - r2() * amp)]);
      }
      ctx.beginPath();
      ctx.moveTo(-40, h);
      ctx.lineTo(pts[0]![0], pts[0]![1]);
      for (let i = 1; i < pts.length; i++) {
        const [px, py] = pts[i - 1]!;
        const [x, y] = pts[i]!;
        ctx.quadraticCurveTo(px, py, (px + x) / 2, (py + y) / 2);
      }
      ctx.lineTo(w + 40, h);
      ctx.closePath();
      const g = ctx.createLinearGradient(0, h * (base - amp), 0, h);
      g.addColorStop(0, cap);
      g.addColorStop(0.35, fill);
      g.addColorStop(1, fill);
      ctx.fillStyle = g;
      ctx.fill();
    };
    hills(0.72, 0.16, '#1a2a62', 'rgba(190, 210, 255, 0.55)', 7);
    hills(0.86, 0.12, '#101b45', 'rgba(220, 232, 255, 0.7)', 11);

    // Menu bar.
    ctx.fillStyle = 'rgba(8, 14, 34, 0.55)';
    ctx.fillRect(0, 0, w, MENU_BAR);
    ctx.fillStyle = 'rgba(235, 242, 255, 0.92)';
    ctx.font = `600 12px ${FONT}`;
    ctx.textBaseline = 'middle';
    const my2 = MENU_BAR / 2 + 0.5;
    this.snowflakeGlyph(ctx, 16, my2, 5.5, 'rgba(235, 242, 255, 0.92)');
    ctx.fillText('Sugrob', 30, my2);
    ctx.font = `12px ${FONT}`;
    if (w > 420) {
      ctx.fillStyle = 'rgba(235, 242, 255, 0.75)';
      ctx.fillText('Файл   Правка   Вид   Окно', 86, my2);
    }
    ctx.textAlign = 'right';
    ctx.fillStyle = 'rgba(235, 242, 255, 0.85)';
    ctx.fillText('Ср 18:05', w - 12, my2);
    this.snowflakeGlyph(ctx, w - 78, my2, 5.5, 'rgba(155, 220, 255, 1)');
    ctx.textAlign = 'left';

    return c;
  }

  private snowflakeGlyph(ctx: CanvasRenderingContext2D, x: number, y: number, r: number, color: string): void {
    ctx.save();
    ctx.strokeStyle = color;
    ctx.lineWidth = 1.3;
    ctx.lineCap = 'round';
    ctx.beginPath();
    for (let k = 0; k < 3; k++) {
      const a = (k * Math.PI) / 3 + Math.PI / 2;
      ctx.moveTo(x - Math.cos(a) * r, y - Math.sin(a) * r);
      ctx.lineTo(x + Math.cos(a) * r, y + Math.sin(a) * r);
    }
    ctx.stroke();
    ctx.restore();
  }

  // ------------------------------------------------------------------ frame

  draw(world: World, view: ViewState): void {
    const ctx = this.ctx;
    ctx.setTransform(1, 0, 0, 1, 0, 0);
    if (this.wallpaper) ctx.drawImage(this.wallpaper, 0, 0);
    ctx.setTransform(this.dpr, 0, 0, this.dpr, 0, 0);

    for (const s of world.surfaces) {
      if (s.kind === 'dock') this.drawDock(s);
      else this.drawWindow(s);
      this.drawDrift(s);
    }

    this.drawParticles(world);
    this.drawCursor(view);
  }

  private drawCursor(view: ViewState): void {
    if (!view.showMitten || !view.pointerInside) return;
    const ctx = this.ctx;
    ctx.save();
    ctx.beginPath();
    ctx.arc(view.pointerX, view.pointerY, MITTEN_RADIUS, 0, Math.PI * 2);
    ctx.fillStyle = view.pointerDown ? 'rgba(255,255,255,0.12)' : 'rgba(255,255,255,0.04)';
    ctx.fill();
    ctx.setLineDash([4, 5]);
    ctx.lineWidth = 1.5;
    ctx.strokeStyle = 'rgba(255,255,255,0.6)';
    ctx.stroke();
    ctx.restore();
  }

  private drawWindow(s: Surface): void {
    const ctx = this.ctx;
    const r = 10;

    ctx.save();
    ctx.shadowColor = 'rgba(0, 4, 20, 0.5)';
    ctx.shadowBlur = 28;
    ctx.shadowOffsetY = 12;
    roundRect(ctx, s.x, s.y, s.w, s.h, r);
    ctx.fillStyle = '#1b2236';
    ctx.fill();
    ctx.restore();

    ctx.save();
    roundRect(ctx, s.x, s.y, s.w, s.h, r);
    ctx.clip();

    const bar = ctx.createLinearGradient(0, s.y, 0, s.y + TITLE_BAR);
    bar.addColorStop(0, '#2d3550');
    bar.addColorStop(1, '#262d45');
    ctx.fillStyle = bar;
    ctx.fillRect(s.x, s.y, s.w, TITLE_BAR);
    ctx.fillStyle = 'rgba(0, 0, 0, 0.35)';
    ctx.fillRect(s.x, s.y + TITLE_BAR, s.w, 1);

    const lights = ['#ff5f57', '#febc2e', '#28c840'];
    lights.forEach((color, i) => {
      ctx.fillStyle = color;
      ctx.beginPath();
      ctx.arc(s.x + 14 + i * 18, s.y + TITLE_BAR / 2, 5.5, 0, Math.PI * 2);
      ctx.fill();
    });

    ctx.font = `600 12px ${FONT}`;
    ctx.textAlign = 'center';
    ctx.textBaseline = 'middle';
    ctx.fillStyle = '#c8d1ea';
    const titleSpace = s.w - 130;
    if (titleSpace > 30) {
      let title = s.title;
      while (title.length > 3 && ctx.measureText(title).width > titleSpace) title = title.slice(0, -2);
      if (title !== s.title) title = title.trimEnd() + '…';
      ctx.fillText(title, s.x + s.w / 2 + 20, s.y + TITLE_BAR / 2 + 0.5);
    }
    ctx.textAlign = 'left';

    const cx = s.x + 16;
    const cy = s.y + TITLE_BAR + 16;
    const cw = s.w - 32;
    if (s.content === 'notes') {
      ctx.fillStyle = '#e7edff';
      ctx.font = `700 14px ${FONT}`;
      ctx.fillText('Зимние планы', cx, cy + 4);
      const widths = [0.92, 0.74, 0.86, 0.55, 0.8, 0.68, 0.9, 0.5];
      let y = cy + 24;
      for (const wf of widths) {
        if (y > s.y + s.h - 12) break;
        roundRect(ctx, cx, y, cw * wf, 6, 3);
        ctx.fillStyle = 'rgba(200, 212, 245, 0.22)';
        ctx.fill();
        y += 16;
      }
    } else {
      const cols = cw > 220 ? 4 : 3;
      const gap = 8;
      const size = (cw - gap * (cols - 1)) / cols;
      const tones = [
        ['#6aa8ff', '#e9f3ff'],
        ['#334d9a', '#b6c9ff'],
        ['#7fd6e8', '#1d3a7a'],
        ['#a7b8ff', '#2a2f6e'],
        ['#ffffff', '#8fb6ea'],
        ['#4b6fd1', '#d3e2ff'],
      ];
      let k = 0;
      for (let y = cy - 4; y + size <= s.y + s.h - 8; y += size + gap) {
        for (let c = 0; c < cols; c++) {
          const [a, b] = tones[k++ % tones.length] as [string, string];
          const x = cx + c * (size + gap);
          const g = ctx.createLinearGradient(x, y, x, y + size);
          g.addColorStop(0, a);
          g.addColorStop(1, b);
          roundRect(ctx, x, y, size, size, 6);
          ctx.fillStyle = g;
          ctx.fill();
        }
      }
    }
    ctx.restore();

    roundRect(ctx, s.x + 0.5, s.y + 0.5, s.w - 1, s.h - 1, r);
    ctx.strokeStyle = 'rgba(255, 255, 255, 0.12)';
    ctx.lineWidth = 1;
    ctx.stroke();
  }

  private drawDock(s: Surface): void {
    const ctx = this.ctx;
    roundRect(ctx, s.x, s.y, s.w, s.h, 16);
    ctx.fillStyle = 'rgba(200, 215, 255, 0.16)';
    ctx.fill();
    ctx.strokeStyle = 'rgba(255, 255, 255, 0.25)';
    ctx.lineWidth = 1;
    ctx.stroke();

    const size = s.h - 14;
    const gap = 8;
    const count = Math.max(1, Math.min(9, Math.floor((s.w - 12) / (size + gap))));
    const total = count * size + (count - 1) * gap;
    let x = s.x + (s.w - total) / 2;
    const y = s.y + 7;
    const palette: [string, string][] = [
      ['#1a2c66', '#0b1430'],
      ['#7cc4ff', '#2d6fd6'],
      ['#ffd27a', '#f08a3c'],
      ['#9be7c4', '#2f9a7a'],
      ['#c8a8ff', '#6a4bd1'],
      ['#ff9aa8', '#d0476b'],
      ['#e6eefc', '#9aa9c8'],
      ['#7ae0ff', '#2a8fb8'],
      ['#ffe08a', '#c9a227'],
    ];
    for (let i = 0; i < count; i++) {
      const [a, b] = palette[i % palette.length]!;
      const g = ctx.createLinearGradient(x, y, x, y + size);
      g.addColorStop(0, a);
      g.addColorStop(1, b);
      roundRect(ctx, x, y, size, size, size * 0.24);
      ctx.fillStyle = g;
      ctx.fill();
      if (i === 0) this.snowflakeGlyph(ctx, x + size / 2, y + size / 2, size * 0.3, '#ffffff');
      else {
        ctx.fillStyle = 'rgba(255, 255, 255, 0.55)';
        roundRect(ctx, x + size * 0.28, y + size * 0.28, size * 0.44, size * 0.44, size * 0.12);
        ctx.fill();
      }
      x += size + gap;
    }
  }

  private drawDrift(s: Surface): void {
    const h = s.drift.heights;
    const peak = s.drift.peak();
    if (peak < 0.4) return;
    const ctx = this.ctx;
    const base = s.y + 1.5;

    const trace = (dy: number): void => {
      ctx.beginPath();
      ctx.moveTo(s.x - 1.5, base + dy);
      let prevX = s.x - 1.5;
      let prevY = base + dy;
      for (let i = 0; i < h.length; i++) {
        const x = s.x + Math.min(s.w, (i + 0.5) * CELL);
        const y = s.y - h[i]! + dy;
        ctx.quadraticCurveTo(prevX, prevY, (prevX + x) / 2, (prevY + y) / 2);
        prevX = x;
        prevY = y;
      }
      ctx.quadraticCurveTo(prevX, prevY, s.x + s.w + 1.5, base + dy);
      ctx.closePath();
    };

    // Soft contact shadow, then the snow body.
    trace(2.5);
    ctx.fillStyle = 'rgba(4, 10, 32, 0.28)';
    ctx.fill();

    trace(0);
    const g = ctx.createLinearGradient(0, s.y - peak, 0, base);
    g.addColorStop(0, '#ffffff');
    g.addColorStop(0.6, '#f1f6ff');
    g.addColorStop(1, '#c9d9f2');
    ctx.fillStyle = g;
    ctx.fill();
    ctx.strokeStyle = 'rgba(255, 255, 255, 0.9)';
    ctx.lineWidth = 0.8;
    ctx.stroke();
  }

  private drawParticles(world: World): void {
    const ctx = this.ctx;
    const sprite = this.sprite;
    const { px, py, pr, pkind, plife } = world;
    for (let i = 0; i < world.count; i++) {
      const kind = pkind[i]!;
      const r = pr[i]!;
      if (kind === FLAKE && sprite) {
        ctx.globalAlpha = Math.min(1, 0.45 + r * 0.22);
        const size = r * 3;
        ctx.drawImage(sprite, px[i]! - size / 2, py[i]! - size / 2, size, size);
      } else if (kind === CLUMP) {
        ctx.globalAlpha = 1;
        ctx.fillStyle = '#f4f8ff';
        ctx.beginPath();
        ctx.arc(px[i]!, py[i]!, r, 0, Math.PI * 2);
        ctx.fill();
      } else if (kind === PUFF && sprite) {
        ctx.globalAlpha = Math.max(0, Math.min(1, plife[i]! * 1.4));
        const size = r * 3.2;
        ctx.drawImage(sprite, px[i]! - size / 2, py[i]! - size / 2, size, size);
      }
    }
    ctx.globalAlpha = 1;
  }
}
