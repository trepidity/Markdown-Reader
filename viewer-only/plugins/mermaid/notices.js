import fs from 'node:fs';
import path from 'node:path';

// Collect license files for packages actually included in the browser bundle.
const metadata = JSON.parse(fs.readFileSync('build/meta.json', 'utf8'));
const packages = new Set();
for (const input of Object.keys(metadata.inputs)) {
  const parts = input.split('/');
  if (parts[0] !== 'node_modules') continue;
  packages.add(parts[1].startsWith('@') ? parts.slice(1, 3).join('/') : parts[1]);
}
const notices = [];
for (const name of [...packages].sort()) {
  const directory = path.join('node_modules', name);
  const pkg = JSON.parse(fs.readFileSync(path.join(directory, 'package.json'), 'utf8'));
  notices.push(`${name} ${pkg.version}\nLicense: ${JSON.stringify(pkg.license)}\n`);
  for (const file of fs.readdirSync(directory).filter(file => /^(licen[cs]e|copying|notice)(\.|$)/i.test(file)).sort()) {
    const filename = path.join(directory, file);
    if (fs.statSync(filename).isFile()) notices.push(fs.readFileSync(filename, 'utf8'));
  }
  notices.push('\n' + '='.repeat(72) + '\n');
}
fs.writeFileSync('build/THIRD-PARTY-NOTICES.txt', notices.join('\n'));
