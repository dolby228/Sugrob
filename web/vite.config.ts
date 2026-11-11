import { defineConfig } from 'vite';

export default defineConfig({
  base: '/Sugrob/',
  build: {
    target: 'es2022',
    outDir: 'dist',
    emptyOutDir: true,
  },
});
