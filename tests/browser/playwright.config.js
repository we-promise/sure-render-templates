const { defineConfig } = require('@playwright/test');

module.exports = defineConfig({
  testDir: '.',
  testMatch: 'sample-app.spec.js',
  workers: 1,
  retries: 0, // Retrying the whole journey would create another household and AI spend.
  timeout: 600_000,
  expect: { timeout: 15_000 },
  outputDir: 'test-results',
  reporter: [['list'], ['html', { open: 'never' }]],
  use: {
    baseURL: process.env.E2E_SAMPLE_URL,
    browserName: 'chromium',
    locale: 'en-US',
    viewport: { width: 1400, height: 1100 },
    screenshot: 'only-on-failure',
    // Tracing starts after signup/login, to keep passwords out of trace input events.
    trace: 'off',
  },
});
