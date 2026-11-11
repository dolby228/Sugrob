/** Light decorative snowfall behind the hero text. Purely visual. */

interface Flake {
  x: number;
  y: number;
  r: number;
  speed: number;
  drift: number;
  phase: number;
  alpha: number;
}

export function startHeroSnow(canvas: HTMLCanvasElement, reducedMotion: boolean): void {
  const ctx = canvas.getContext('2d');
  if (!ctx) return;

  let width = 0;
  let height = 0;
  let flakes: Flake[] = [];
  let visible = true;
  let last = 0;

  const makeFlake = (y?: number): Flake => ({
    x: Math.random() * width,
    y: y ?? Math.random() * height,
    r: 0.6 + Math.random() * 1.9,
    speed: 14 + Math.random() * 32,
    drift: 6 + Math.random() * 14,
    phase: Math.random() * Math.PI * 2,
    alpha: 0.25 + Math.random() * 0.55,
  });

  const resize = (): void => {
    const dpr = Math.min(window.devicePixelRatio || 1, 2);
    const rect = canvas.getBoundingClientRect();
    width = rect.width;
    height = rect.height;
    canvas.width = Math.round(width * dpr);
    canvas.height = Math.round(height * dpr);
    ctx.setTransform(dpr, 0, 0, dpr, 0, 0);
    const target = Math.min(160, Math.round((width * height) / (reducedMotion ? 16000 : 7000)));
    flakes = Array.from({ length: target }, () => makeFlake());
    if (reducedMotion) draw();
  };

  const draw = (): void => {
    ctx.clearRect(0, 0, width, height);
    ctx.fillStyle = '#ffffff';
    for (const f of flakes) {
      ctx.globalAlpha = f.alpha;
      ctx.beginPath();
      ctx.arc(f.x, f.y, f.r, 0, Math.PI * 2);
      ctx.fill();
    }
    ctx.globalAlpha = 1;
  };

  const tick = (now: number): void => {
    const dt = Math.min(0.05, (now - last) / 1000 || 0);
    last = now;
    for (const f of flakes) {
      f.phase += dt * 0.8;
      f.y += f.speed * dt;
      f.x += Math.sin(f.phase) * f.drift * dt;
      if (f.y > height + 4) Object.assign(f, makeFlake(-4));
    }
    draw();
    if (visible) requestAnimationFrame(tick);
    else running = false;
  };

  let running = false;
  const start = (): void => {
    if (running || !visible) return;
    running = true;
    last = performance.now();
    requestAnimationFrame(tick);
  };

  resize();
  new ResizeObserver(resize).observe(canvas);

  if (reducedMotion) return;

  new IntersectionObserver(([entry]) => {
    visible = Boolean(entry?.isIntersecting);
    start();
  }).observe(canvas);

  start();
}
