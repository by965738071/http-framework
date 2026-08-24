import { defineConfig } from 'vite';
import { svelte } from '@sveltejs/vite-plugin-svelte';

export default defineConfig({
  plugins: [svelte()],
  server: {
    proxy: {
      '/api': 'http://127.0.0.1:9000',
      '/admin': 'http://127.0.0.1:9000',
    }
  },
  build: {
    outDir: '../public/app',
    emptyOutDir: true,
  },
  base: '/app/',
});
