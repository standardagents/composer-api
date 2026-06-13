import { defineConfig } from "vitest/config";

export default defineConfig({
  resolve: {
    alias: {
      "cloudflare:workers": "./worker/test-cloudflare-workers.ts",
    },
  },
  test: {
    environment: "node",
    include: [
      "worker/**/*.test.ts",
      "src/**/*.test.ts",
      "scripts/**/*.test.mjs",
    ],
    testTimeout: 10000,
  },
});
