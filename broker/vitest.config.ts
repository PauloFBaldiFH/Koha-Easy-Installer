import { defineConfig } from "vitest/config";

// Unit tests run in Node: they cover the pure modules (names, signatures,
// network ranges, staff auth helpers, provisioning steps against a fake API).
// Worker-only modules (index.ts, provisioner.ts) are checked by tsc and by
// `wrangler deploy --dry-run`.
export default defineConfig({
  test: { environment: "node", include: ["test/**/*.test.ts"] },
});
