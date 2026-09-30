// J10 — documents: upload a file (.md, .pdf, .docx) or paste text.
// The file's bytes are encrypted by Vault; recovery returns them bit-for-bit.
import { test, expect } from '@playwright/test';
import { createHash } from 'node:crypto';
import { readFile } from 'node:fs/promises';
import { pageAs } from './auth';
import { api } from './api';

const stamp = Date.now();
// A minimal, valid PDF and a Markdown note, built in the test (no fixtures on disk).
const PDF = Buffer.from(
  '%PDF-1.4\n1 0 obj<</Type/Catalog/Pages 2 0 R>>endobj\n2 0 obj<</Type/Pages/Kids[3 0 R]/Count 1>>endobj\n'
  + '3 0 obj<</Type/Page/Parent 2 0 R/MediaBox[0 0 200 200]>>endobj\ntrailer<</Root 1 0 R>>\n%%EOF\n'
  + `% durin upload test ${stamp}\n`, 'latin1');
const MD = Buffer.from(`# Durin upload test ${stamp}\n\nQuarterly **settlement** figures: 42.\n`, 'utf8');
const sha = (b: Buffer) => createHash('sha256').update(b).digest('hex');

async function uploadFile(page: import('@playwright/test').Page, fileName: string, mimeType: string, buffer: Buffer) {
  await page.goto('/documents');
  await page.getByRole('button', { name: 'Upload document' }).click();
  await expect(page.getByTestId('mode-file')).toHaveAttribute('aria-selected', 'true');
  await page.getByTestId('file-input').setInputFiles({ name: fileName, mimeType, buffer });
  await expect(page.getByTestId('picked-file')).toContainText(fileName);
  await expect(page.locator('#d-name')).toHaveValue(fileName);
  await page.getByTestId('document-submit').click();
  await expect(page.getByTestId('documents-table')).toContainText(fileName);
}

test('J10.1 upload a Markdown file; it comes back as text, integrity verified', async ({ browser }) => {
  const { context, page } = await pageAs(browser, 'raymon');
  const name = `notes-${stamp}.md`;
  await uploadFile(page, name, 'text/markdown', MD);
  await page.getByRole('link', { name }).click();
  await page.getByTestId('open-content').click();
  await expect(page.getByTestId('document-payload')).toContainText('Quarterly **settlement** figures: 42.');
  await expect(page.getByTestId('integrity')).toContainText('SHA-256 matches the upload');
  await expect(page.getByTestId('download-file')).toHaveCount(0);
  await context.close();
});

test('J10.2 upload a PDF; Vault encrypts the bytes and the download is bit-for-bit identical', async ({ browser }) => {
  const { context, page } = await pageAs(browser, 'raymon');
  const name = `statement-${stamp}.pdf`;
  await uploadFile(page, name, 'application/pdf', PDF);

  // PostgreSQL holds ciphertext only; size and checksum describe the real file.
  const { json } = await api(page, '/documents', { tenant: 'acme' });
  const doc = json.data.find((d: any) => d.name === name);
  expect(doc.content_type).toBe('application/pdf');
  expect(doc.size_bytes).toBe(PDF.length);
  expect(doc.checksum).toBe(sha(PDF));
  const raw = await api(page, `/documents/${doc.id}/raw`, { tenant: 'acme' });
  expect(raw.json.data.ciphertext).toMatch(/^vault:v\d+:/);

  await page.getByRole('link', { name }).click();
  await page.getByTestId('open-content').click();
  await expect(page.getByTestId('document-payload')).toContainText(`${name} · `);
  await expect(page.getByTestId('integrity')).toContainText('SHA-256 matches the upload');
  const [download] = await Promise.all([page.waitForEvent('download'), page.getByTestId('download-file').click()]);
  expect(download.suggestedFilename()).toBe(name);
  const got = await readFile(await download.path());
  expect(sha(got)).toBe(sha(PDF));
  await context.close();
});

test('J10.3 the API refuses unsupported, mislabelled and oversized files', async ({ browser }) => {
  const { context, page } = await pageAs(browser, 'raymon');
  const post = (data: object) => api(page, '/documents', { method: 'POST', tenant: 'acme', data: { name: 'x', classification: 'INTERNAL', ...data } });

  const exe = await post({ content_type: 'application/x-msdownload', payload: Buffer.from('MZ').toString('base64') });
  expect(exe.status).toBe(415);
  const fakePdf = await post({ content_type: 'application/pdf', payload: Buffer.from('not a pdf at all').toString('base64') });
  expect(fakePdf.status).toBe(400);
  const huge = await post({ content_type: 'application/pdf', payload: Buffer.concat([Buffer.from('%PDF-'), Buffer.alloc(5 * 1024 * 1024)]).toString('base64') });
  expect(huge.status).toBe(413);

  // The console refuses the same before sending anything.
  await page.goto('/documents');
  await page.getByRole('button', { name: 'Upload document' }).click();
  await page.getByTestId('file-input').setInputFiles({ name: 'tool.exe', mimeType: 'application/octet-stream', buffer: Buffer.from('MZ') });
  await expect(page.getByRole('alert')).toContainText('Upload a .md, .pdf or .docx file.');
  await context.close();
});

test('J10.4 pasting text still works', async ({ browser }) => {
  const { context, page } = await pageAs(browser, 'raymon');
  const name = `pasted-${stamp}`;
  await page.goto('/documents');
  await page.getByRole('button', { name: 'Upload document' }).click();
  await page.getByTestId('mode-text').click();
  await page.locator('#d-name').fill(name);
  await page.locator('#d-payload').fill('Pasted, protected, recoverable.');
  await page.getByTestId('document-submit').click();
  await expect(page.getByTestId('documents-table')).toContainText(name);
  await context.close();
});
