/** Wires the snow world, renderer, input and the DOM controls together. */
import { Input } from './input';
import { Renderer } from './render';
import { World, type Intensity, type Tool, type WindDir } from './world';

const INTENSITY_LABEL: Record<Intensity, string> = {
  light: 'лёгкий',
  steady: 'ровный',
  blizzard: 'метель',
};
const WIND_LABEL: Record<string, string> = { '-1': 'влево', '0': 'штиль', '1': 'вправо' };

export function createSnowDemo(root: HTMLElement, reducedMotion: boolean): void {
  const canvas = root.querySelector<HTMLCanvasElement>('.demo-canvas');
  const playBtn = root.querySelector<HTMLButtonElement>('.demo-play');
  const pauseBtn = root.querySelector<HTMLButtonElement>('.demo-pause');
  const clearBtn = root.querySelector<HTMLButtonElement>('.demo-clear');
  const status = root.querySelector<HTMLElement>('[data-demo-status]');
  if (!canvas || !playBtn || !pauseBtn) return;

  let renderer: Renderer;
  try {
    renderer = new Renderer(canvas);
  } catch {
    return;
  }

  const world = new World();
  world.density = reducedMotion ? 0.4 : 1;

  const announce = (text: string): void => {
    if (status) status.textContent = text;
  };

  const radios = (name: string): HTMLInputElement[] =>
    Array.from(root.querySelectorAll<HTMLInputElement>(`input[name="${name}"]`));
  const check = (name: string, value: string): void => {
    for (const r of radios(name)) r.checked = r.value === value;
  };

  const setWind = (dir: WindDir, fromKeyboard = false): void => {
    world.windDir = dir;
    check('wind', String(dir));
    if (fromKeyboard) announce(`Ветер: ${WIND_LABEL[String(dir)]}`);
  };
  const setIntensity = (level: Intensity, fromKeyboard = false): void => {
    world.intensity = level;
    check('intensity', level);
    if (fromKeyboard) announce(`Снегопад: ${INTENSITY_LABEL[level]}`);
  };

  const input = new Input(canvas, world, {
    onWind: (dir) => setWind(dir, true),
    onIntensity: (level) => setIntensity(level, true),
  });

  for (const r of radios('wind')) r.addEventListener('change', () => setWind(Number(r.value) as WindDir));
  for (const r of radios('intensity')) r.addEventListener('change', () => setIntensity(r.value as Intensity));
  for (const r of radios('tool')) {
    r.addEventListener('change', () => {
      world.tool = r.value as Tool;
      // Switching away from the shovel drops what it carries.
      if (world.tool !== 'shovel' && world.shovelLoad > 0) {
        world.dump(input.view.pointerX, input.view.pointerY, 0, 0);
      }
      input.refresh();
      kick();
    });
  }

  clearBtn?.addEventListener('click', () => {
    world.clearAll();
    announce('Снег убран');
    kick();
  });

  // ------------------------------------------------------------ pause/play

  let paused = reducedMotion;
  const syncPause = (): void => {
    pauseBtn.setAttribute('aria-pressed', String(paused));
    pauseBtn.textContent = paused ? 'Продолжить' : 'Пауза';
    input.running = !paused;
  };
  const setPaused = (value: boolean): void => {
    paused = value;
    playBtn.hidden = true;
    syncPause();
    kick();
  };
  pauseBtn.addEventListener('click', () => setPaused(!paused));
  playBtn.addEventListener('click', () => {
    setPaused(false);
    canvas.focus({ preventScroll: true });
  });
  if (reducedMotion) playBtn.hidden = false;
  syncPause();

  // ---------------------------------------------------------------- sizing

  const resize = (): void => {
    const rect = canvas.getBoundingClientRect();
    if (rect.width < 1 || rect.height < 1) return;
    const dpr = Math.min(window.devicePixelRatio || 1, 2);
    world.resize(Math.round(rect.width), Math.round(rect.height));
    renderer.resize(world.width, world.height, dpr);
    renderer.draw(world, input.view);
  };
  new ResizeObserver(resize).observe(canvas);
  resize();

  // ------------------------------------------------------------------ loop

  let visible = true;
  let running = false;
  let last = 0;

  const frame = (now: number): void => {
    const dt = Math.min(1 / 30, Math.max(0, (now - last) / 1000));
    last = now;
    if (!paused) world.step(dt);
    input.update(dt);
    renderer.draw(world, input.view);
    // While paused, only keep drawing as long as someone is interacting.
    const idle = paused && !input.view.pointerInside && !input.view.pointerDown;
    if (visible && !document.hidden && !idle) requestAnimationFrame(frame);
    else running = false;
  };

  function kick(): void {
    if (running || !visible || document.hidden) return;
    running = true;
    last = performance.now();
    requestAnimationFrame(frame);
  }

  new IntersectionObserver(([entry]) => {
    visible = Boolean(entry?.isIntersecting);
    kick();
  }).observe(canvas);
  document.addEventListener('visibilitychange', kick);
  canvas.addEventListener('pointermove', kick);
  canvas.addEventListener('pointerdown', kick);
  canvas.addEventListener('keydown', kick);
  kick();
}
