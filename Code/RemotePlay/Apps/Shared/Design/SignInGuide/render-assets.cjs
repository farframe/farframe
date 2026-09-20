// Run with Node.js and sharp available (npm install --no-save sharp@0.35.4).
// SVG sources are approved reference illustrations, not captured sign-in data.
const fs = require('node:fs/promises');
const path = require('node:path');
const sharp = require('sharp');
const pages = [
  ['01-sign-in', 'SignInGuideEmail'],
  ['02-qr-and-email', 'SignInGuideCodeAndEmail'],
  ['03-open-email', 'SignInGuideOpenEmail'],
  ['04-confirm-passkey', 'SignInGuidePasskey'],
  ['05-enter-code', 'SignInGuideEnterCode'],
];
(async () => {
  const catalog = path.resolve(__dirname, '../../Resources/HelpGuides.xcassets');
  for (const [source, name] of pages) {
    const output = path.join(catalog, `${name}.imageset`);
    await fs.mkdir(output, { recursive: true });
    await sharp(path.join(__dirname, `${source}.svg`), { density: 144 })
      .resize({ width: 1600 }).png().toFile(path.join(output, `${name}.png`));
    await fs.writeFile(path.join(output, 'Contents.json'), JSON.stringify({
      images: [{ filename: `${name}.png`, idiom: 'universal' }],
      info: { author: 'xcode', version: 1 }
    }, null, 2) + '\n');
  }
  console.log('Rendered all five guide assets at 1600px width. PNG metadata stripped by sharp.');
})().catch(error => { console.error(error); process.exitCode = 1; });
