import { defineConfig } from "vitest/config";

export default defineConfig({
  test: {
    environment: "node",
    include: ["worker/**/*.test.ts"],
    testTimeout: 10000
  }
});
