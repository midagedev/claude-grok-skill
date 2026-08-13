#!/usr/bin/env node
// Renders assets/og.html to assets/og.png (1280x640 — GitHub social preview).
// Usage: PLAYWRIGHT_DIR=<abs path to a node_modules/playwright> node assets/render-og.mjs
const { chromium } = await import(
  (process.env.PLAYWRIGHT_DIR || 'playwright') + '/index.mjs'
).catch(() => import('playwright'));
import { fileURLToPath } from 'node:url';
import path from 'node:path';

const here = path.dirname(fileURLToPath(import.meta.url));
const browser = await chromium.launch();
const page = await browser.newPage({ viewport: { width: 1280, height: 640 }, deviceScaleFactor: 2 });
await page.goto('file://' + path.join(here, 'og.html'));
await page.waitForTimeout(300);
await page.screenshot({ path: path.join(here, 'og.png') });
await browser.close();
console.log('wrote', path.join(here, 'og.png'));
