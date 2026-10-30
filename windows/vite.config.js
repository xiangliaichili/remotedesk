import { defineConfig } from "vite";

// Tauri 期望固定端口，且不要清屏覆盖 Rust 的日志
export default defineConfig({
  clearScreen: false,
  server: {
    port: 1420,
    strictPort: true,
  },
  build: {
    target: "chrome105",
    minify: false,
    sourcemap: false,
  },
});
