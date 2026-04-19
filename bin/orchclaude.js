#!/usr/bin/env node
'use strict';
const { spawnSync } = require('child_process');
const path = require('path');

const pkgDir = path.join(__dirname, '..');
const args = process.argv.slice(2);

let result;
if (process.platform === 'win32') {
  const ps1 = path.join(pkgDir, 'orchclaude.ps1');
  result = spawnSync(
    'powershell.exe',
    ['-ExecutionPolicy', 'Bypass', '-File', ps1, ...args],
    { stdio: 'inherit' }
  );
} else {
  const sh = path.join(pkgDir, 'orchclaude.sh');
  result = spawnSync('bash', [sh, ...args], { stdio: 'inherit' });
}

process.exit(result.status != null ? result.status : 1);
