import './style.css';
import { startHeroSnow } from './hero-snow';
import { createSnowDemo } from './snow/demo';

const reducedMotion = window.matchMedia('(prefers-reduced-motion: reduce)').matches;

const heroCanvas = document.querySelector<HTMLCanvasElement>('.hero-snow');
if (heroCanvas) startHeroSnow(heroCanvas, reducedMotion);

const demo = document.querySelector<HTMLElement>('[data-demo]');
if (demo) createSnowDemo(demo, reducedMotion);
