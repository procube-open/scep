import { defineConfig } from 'vite';
import react from '@vitejs/plugin-react';

// https://vitejs.dev/config/
export default defineConfig({
    plugins: [react()],
    define: {
        'process.env': process.env,
    },
    build: {
      outDir: 'build',
    },
    server: {
        host: true,
        proxy: {
          '/api': {
            target: 'http://localhost:3000',
            changeOrigin: true
          },
          '/admin': {
            target: 'http://localhost:3000',
            changeOrigin: true
          },
        }
    },
    base: '/caweb/',
});
