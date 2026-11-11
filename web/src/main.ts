import './style.css';
import { startHeroSnow } from './hero-snow';

const reducedMotion = window.matchMedia('(prefers-reduced-motion: reduce)').matches;

const heroCanvas = document.querySelector<HTMLCanvasElement>('.hero-snow');
if (heroCanvas) startHeroSnow(heroCanvas, reducedMotion);
