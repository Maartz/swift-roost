import assert from 'node:assert/strict';
import { execFileSync, spawn } from 'node:child_process';
import { existsSync, mkdirSync, writeFileSync } from 'node:fs';
import { createServer } from 'node:net';
import { fileURLToPath } from 'node:url';
import { join } from 'node:path';
import { chromium } from 'playwright';

// Uses the caller's isolated DB_* database, already migrated. No demo seeding.
const app = fileURLToPath(new URL('..', import.meta.url));
const artifacts = fileURLToPath(new URL('artifacts/', import.meta.url));
mkdirSync(artifacts, { recursive: true });
const binary = join(execFileSync('swift', ['build', '--show-bin-path'], { cwd: app, encoding: 'utf8' }).trim(), 'RoostExample');
assert(existsSync(binary), 'Build and migrate RoostExample first');
const reservation = createServer();
await new Promise(resolve => reservation.listen(0, '127.0.0.1', resolve));
const port = reservation.address().port;
await new Promise(resolve => reservation.close(resolve));
const url = `http://127.0.0.1:${port}`;
const server = spawn(binary, [], { cwd: app, env: { ...process.env, ROOST_ENV: 'test', ROOST_DEMO: '0', ROOST_HOST: '127.0.0.1', ROOST_PORT: String(port) } });
let log = '', exited = false;
const serverExit = new Promise(resolve => server.once('exit', (code, signal) => { exited = true; resolve({ code, signal }); }));
server.stdout.on('data', data => { log = (log + data).slice(-50000); });
server.stderr.on('data', data => { log = (log + data).slice(-50000); });
const delay = ms => new Promise(resolve => setTimeout(resolve, ms));
async function eventually(check, message, timeout = 12000) {
    const end = Date.now() + timeout;
    while (Date.now() < end) { if (await check()) return; await delay(50); }
    throw new Error(message);
}
let browser;
try {
    await eventually(async () => { try { return (await fetch(url + '/auth/register')).ok; } catch { return false; } }, 'Server did not start');
    const chrome = '/Applications/Google Chrome.app/Contents/MacOS/Google Chrome';
    browser = await chromium.launch({ headless: true, ...(existsSync(chrome) ? { executablePath: chrome } : {}) });
    const context = await browser.newContext({ viewport: { width: 1100, height: 1000 } });
    const page = await context.newPage();
    const errors = [];
    page.on('pageerror', error => errors.push(error.message));
    async function register(page) {
        await page.goto(url + '/auth/register');
        await page.locator('[name=email]').fill(`live-${crypto.randomUUID()}@example.test`);
        await page.locator('[name=password]').fill('A-test-password-2026');
        await page.locator('form button[type=submit]').click();
        await page.waitForURL(url + '/bookmarks');
        await connected(page);
    }
    async function connected(page) {
        await page.locator('[data-esw-live][data-esw-state="connected"]').waitFor();
    }
    const count = async name => Number(await page.locator(`[data-filter-count="${name}"]`).textContent());
    await register(page);
    const ids = [];
    for (const title of ['First live link', 'Second live link']) {
        await page.goto(url + '/bookmarks/new');
        await page.locator('[name=title]').fill(title);
        await page.locator('[name=url]').fill('https://example.com/article');
        await page.locator('[name=note]').fill('A note worth keeping');
        await page.locator('form.editor-form button[type=submit]').click();
        await page.waitForURL(/\/bookmarks\/[0-9a-f-]+$/i);
        ids.push(page.url().split('/').at(-1));
    }
    await page.goto(url + '/bookmarks?filter=all');
    await connected(page);
    assert.equal(await count('all'), 2);
    assert.equal(await count('unread'), 2);
    await page.evaluate(id => { window.savedRow = document.getElementById('bookmark-' + id); }, ids[0]);
    let navigations = 0;
    page.on('framenavigated', frame => { if (frame === page.mainFrame()) navigations++; });
    await page.locator(`#bookmark-${ids[0]} .read-toggle`).click();
    await eventually(async () => await count('finished') === 1, 'Read event did not update counts');
    assert.equal(navigations, 0, 'Read should not navigate');
    assert.equal(await page.evaluate(id => window.savedRow === document.getElementById('bookmark-' + id), ids[0]), true);
    await page.screenshot({ path: join(artifacts, 'bookmarks-desktop.png'), fullPage: true });
    await page.setViewportSize({ width: 390, height: 900 });
    assert(await page.evaluate(() => document.documentElement.scrollWidth <= innerWidth), 'Mobile overflow');
    await page.screenshot({ path: join(artifacts, 'bookmarks-mobile.png'), fullPage: true });
    await page.setViewportSize({ width: 1100, height: 1000 });

    await context.setOffline(true);
    await page.locator('[data-esw-state="disconnected"]').waitFor();
    await page.locator(`#bookmark-${ids[1]} .read-toggle`).click();
    assert(await page.locator('.live-offline').isVisible());
    await context.setOffline(false);
    await eventually(async () => await count('finished') === 2, 'Queued offline change did not resume');
    await connected(page);

    // Lose the response after the mutation commits. The retry must keep its ID/revision.
    const replies = [];
    let drop = true;
    await page.route('**/_live/bookmarks/*/event', async route => {
        const request = route.request().postDataJSON();
        const response = await route.fetch();
        const result = await response.json();
        replies.push({ id: request.id, revision: result.revision });
        if (drop) { drop = false; await route.abort('failed'); }
        else await route.fulfill({ response });
    });
    await page.locator(`#bookmark-${ids[0]} .read-toggle`).click();
    await eventually(async () => replies.length >= 2 && await page.locator('[data-esw-live]').getAttribute('aria-busy') === 'false', 'Lost response was not retried');
    assert.deepEqual(replies[0], replies[1], 'Retry must return the original acknowledgement');
    assert.equal(await count('finished'), 1);
    await page.unroute('**/_live/bookmarks/*/event');

    // A rejected handler is visible; resynchronizing does not silently erase the error.
    await page.evaluate(async () => {
        const { connectLiveViews } = await import('/_live/bookmarks/assets/esw-live.js');
        connectLiveViews()[0].push('unknown');
    });
    await page.locator('.live-error').waitFor({ state: 'visible' });
    await connected(page);
    assert.equal(await count('finished'), 1);
    await page.locator(`#bookmark-${ids[0]} .read-toggle`).click();
    await eventually(async () => await count('finished') === 2 && !await page.locator('.live-error').isVisible(), 'Success did not clear the error');

    const second = await browser.newContext();
    const other = await second.newPage();
    await register(other);
    const own = await other.locator('[data-esw-live]').evaluate(root => ({ event: root.dataset.eswEvent, csrf: root.dataset.eswCsrf, revision: Number(root.dataset.eswRevision) }));
    const alice = await page.locator('[data-esw-live]').evaluate(root => ({ stream: root.dataset.eswStream, event: root.dataset.eswEvent }));
    assert.equal((await second.request.get(url + alice.stream)).status(), 403, 'Another session opened the stream');
    assert.equal((await second.request.post(url + alice.event, { headers: { 'X-CSRF-Token': own.csrf }, data: { id: crypto.randomUUID(), name: 'read', values: { id: [ids[0]], read: ['false'] }, baseRevision: own.revision } })).status(), 403);
    assert.equal((await second.request.post(url + own.event, { headers: { 'X-CSRF-Token': own.csrf }, data: { id: crypto.randomUUID(), name: 'read', values: { id: [ids[0]], read: ['false'] }, baseRevision: own.revision } })).status(), 404, 'Live handler bypassed owner scope');
    assert.equal((await (await context.request.get(url + '/api/bookmarks/' + ids[0])).json()).read, true);
    const noCSRF = await context.request.post(url + alice.event, { data: { id: crypto.randomUUID(), name: 'read', values: {}, baseRevision: 1 } });
    assert.equal(noCSRF.status(), 403);

    // The initial HTML works as a native form without JavaScript.
    const native = await browser.newContext({ javaScriptEnabled: false, storageState: await context.storageState() });
    const plain = await native.newPage();
    await plain.goto(url + '/bookmarks?filter=all');
    await plain.locator(`#bookmark-${ids[0]} .read-toggle`).click();
    await plain.waitForLoadState();
    await eventually(async () => Number(await plain.locator('[data-filter-count="finished"]').textContent()) === 1, 'Native POST fallback failed');
    await native.close();

    await page.goto(url + '/bookmarks?filter=unread');
    await connected(page);
    await page.locator('.read-toggle').click();
    await page.locator('.empty-state').waitFor();
    assert.equal(await page.evaluate(() => document.activeElement.id), 'queue-heading', 'Focus was lost when the last row disappeared');

    const tab = await context.newPage();
    await tab.goto(url + '/bookmarks');
    await connected(tab);
    await page.getByRole('button', { name: 'Log out' }).click();
    await page.waitForURL(url + '/auth/login');
    await tab.locator('[data-esw-state="expired"]').waitFor({ timeout: 12000 });
    assert.deepEqual(errors, [], 'Browser exceptions');

    // Leave Bob's SSE response open while stopping the process.
    await other.reload();
    await connected(other);
    server.kill('SIGTERM');
    await eventually(() => exited, 'Open live streams blocked graceful shutdown', 8000);
    assert.equal((await serverExit).code, 0);
    console.log('Live bookmarks: SSR, updates, keyed DOM, offline recovery, lost replies, errors, ownership, CSRF, native forms, logout, and graceful shutdown passed.');
} finally {
    await browser?.close();
    if (!exited) {
        server.kill('SIGTERM');
        for (let i = 0; i < 40 && !exited; i++) await delay(100);
        if (!exited) server.kill('SIGKILL');
        await serverExit;
    }
    writeFileSync(join(artifacts, 'server.log'), log);
}
