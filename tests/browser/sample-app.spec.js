const { test, expect } = require('@playwright/test');
const { randomBytes } = require('node:crypto');

// This suite deliberately has no API key, Render provisioning, seed or delete path.
// Every mutation belongs to the newly registered synthetic user's own household.
test.beforeAll(() => {
  const url = new URL(process.env.E2E_SAMPLE_URL || 'http://invalid');
  expect(url.protocol, 'Use the approved persistent sample HTTPS origin').toBe('https:');
  expect(url.username + url.password + url.search + url.hash).toBe('');
  expect(['', '/']).toContain(url.pathname);
  expect(process.env.E2E_CONFIRM_SAMPLE_DATA, 'Authorize isolated synthetic records and real AI usage').toBe('yes');
  expect(process.env.E2E_ADMIN_ESTABLISHED, 'The intended administrator must exist before test signup').toBe('yes');
});

test('stable Simple AI: login, worker-backed finance, grounded AI conversation', async ({ page, context }, testInfo) => {
  const run = `e2e-${Date.now()}-${randomBytes(3).toString('hex')}`;
  const email = `${run}@example.com`;
  const password = `E2e!${randomBytes(24).toString('hex')}`;
  const accountName = `E2E cash ${run}`;
  const transactionName = `E2E coffee ${run}`;
  const errors = [];
  const failedRequests = [];
  page.on('response', response => {
    if (response.status() >= 400 && response.url().startsWith(process.env.E2E_SAMPLE_URL)) {
      failedRequests.push({ path: new URL(response.url()).pathname, status: response.status() });
    }
  });
  page.on('pageerror', error => errors.push(error.message));
  let tracing = false;

  try {
    await test.step('Create an isolated synthetic household and complete onboarding', async () => {
      await page.goto('/registration/new');
      const registration = page.locator('form[action="/registration"]');
      await registration.locator('input[name="user[email]"]').fill(email);
      await registration.locator('input[name="user[password]"]').fill(password);
      await registration.locator('input[name="user[password_confirmation]"]').fill(password);
      await registration.locator('[type="submit"]').click();
      await expect(page).toHaveURL(/\/onboarding/);
      await page.locator('input[name="user[first_name]"]').fill('E2E');
      await page.locator('input[name="user[last_name]"]').fill(run);
      await page.locator('input[name="user[family_attributes][name]"]').fill(`E2E sample ${run}`);
      await page.locator('form[action^="/users/"] [type="submit"]').click();
      await expect(page).toHaveURL(/\/onboarding\/preferences/);
      // Use the Blueprint's normal English/USD defaults, including real Stimulus controls.
      await expect(page.locator('[name="user[family_attributes][currency]"]')).toHaveValue('USD');
      await page.locator('form[action^="/users/"] [type="submit"]').click();
      await expect(page).toHaveURL(/\/onboarding\/goals/);
      await page.locator('form[action^="/users/"] [type="submit"]').click();
      await page.goto('/');
      await expect(page.locator('h1').first()).toContainText('E2E');
    });

    await test.step('Log in from a fresh browser session', async () => {
      await context.clearCookies();
      await page.goto('/sessions/new');
      const login = page.locator('form[action="/sessions"]');
      await login.locator('input[type="email"]').fill(email);
      await login.locator('input[type="password"]').fill(password);
      await login.locator('[type="submit"]').click();
      await expect(page.locator('h1').first()).toContainText('E2E');
    });

    await context.tracing.start({ screenshots: true, snapshots: true });
    tracing = true;

    await test.step('Create a cash account and expense using browser forms', async () => {
      await page.goto('/depositories/new');
      const account = page.locator('form[action="/depositories"]');
      await account.locator('[name="account[name]"]').fill(accountName);
      await account.locator('[name="account[balance]"]').fill('1000');
      await account.locator('[type="submit"]').click();
      await expect(page).toHaveURL(/\/accounts\/[0-9a-f-]{36}/);
      const accountId = new URL(page.url()).pathname.split('/')[2];
      await page.goto(`/transactions/new?account_id=${accountId}`);
      const transaction = page.locator('form[action="/transactions"]');
      await transaction.locator('[name="entry[name]"]').fill(transactionName);
      await transaction.locator('[name="entry[amount]"]').fill('42.17');
      const [saved] = await Promise.all([
        page.waitForResponse(response => new URL(response.url()).pathname === '/transactions' && response.request().method() === 'POST'),
        transaction.locator('[type="submit"]').click(),
      ]);
      expect([302, 303]).toContain(saved.status());
      await page.goto('/transactions');
      await expect(page.getByText(transactionName, { exact: true }).first()).toBeVisible();
    });

    await test.step('Wait for the separate worker to materialize the new balance', async () => {
      await expect.poll(async () => {
        await page.goto('/accounts');
        return page.locator('body').innerText();
      }, { timeout: 180_000, intervals: [1000, 3000, 5000] }).toContain('957.83');
      await expect(page.getByText(accountName, { exact: true }).first()).toBeVisible();
    });

    await test.step('Ask AI for synthetic account data and verify a persisted answer', async () => {
      await page.goto('/');
      const consent = page.locator('form').filter({ has: page.locator('input[name="user[ai_enabled]"]') });
      if (await consent.count()) {
        await consent.locator('[type="submit"]').click();
      }
      await page.goto('/chats/new');
      const chat = page.locator('form[action="/chats"]');
      await expect(chat.locator('[name="chat[ai_model]"]')).toHaveValue('gpt-4o-mini');
      await chat.locator('textarea').fill(`Look up my account named "${accountName}". What is its current balance in USD? Use my account data, and keep your answer to one sentence.`);
      await chat.locator('[type="submit"]').click();
      await expect(page).toHaveURL(/\/chats\/[0-9a-f-]{36}/);
      const chatPath = new URL(page.url()).pathname;
      // Scope to assistant prose: the user prompt and pending bubble cannot pass.
      const replies = page.locator('[id^="assistant_message_"] .prose--ai-chat');
      await expect(replies.last()).toContainText('957.83', { timeout: 180_000 });
      await page.reload();
      await expect(replies.last()).toContainText('957.83');

      const priorReplies = await replies.count();
      const followup = page.locator(`form[action="${chatPath}/messages"]`);
      await followup.locator('textarea').fill(`Find the expense named "${transactionName}" in my transactions. What is its amount in USD? Keep your answer to one sentence.`);
      await followup.locator('[type="submit"]').click();
      await expect.poll(() => replies.count(), { timeout: 180_000 }).toBeGreaterThan(priorReplies);
      await expect(replies.last()).toContainText('42.17', { timeout: 180_000 });
      await page.reload();
      await expect(replies.last()).toContainText('42.17');
      await page.screenshot({ path: testInfo.outputPath('ai-finance-result.png'), fullPage: true });
      await testInfo.attach('scenario-records', {
        body: JSON.stringify({ run, email, accountName, transactionName, chatPath, outcome: 'passed' }, null, 2),
        contentType: 'application/json',
      });
    });
    expect(errors, 'Browser JavaScript errors').toEqual([]);
  } finally {
    await testInfo.attach('browser-errors', { body: JSON.stringify({ errors, failedRequests }), contentType: 'application/json' });
    if (tracing) await context.tracing.stop({ path: testInfo.outputPath('trace.zip') });
    // Preserve only this scenario's identifiers, never its generated password.
    await testInfo.attach('synthetic-household', { body: JSON.stringify({ run, email }), contentType: 'application/json' });
  }
});
