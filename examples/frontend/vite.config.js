import { defineConfig } from 'vite';
import { svelte } from '@sveltejs/vite-plugin-svelte';
import tailwindcss from '@tailwindcss/vite';

export default defineConfig({
  plugins: [tailwindcss(), svelte()],
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
