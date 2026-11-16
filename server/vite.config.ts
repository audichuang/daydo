import { defineConfig } from 'vitest/config';
import { voidPlugin } from 'void';

export default defineConfig({
  plugins: [voidPlugin()],
  test: {
    setupFiles: ['./tests/helpers/scopeMocks.ts'],
  },
});
