'use strict';
const { execSync } = require('child_process');
const path = require('path');

if (process.platform !== 'win32') {
  const sh = path.join(__dirname, '..', 'orchclaude.sh');
  try {
    execSync(`chmod +x "${sh}"`);
    console.log('orchclaude: orchclaude.sh is now executable');
  } catch (_) {
    // non-fatal — user can run: chmod +x manually
  }
}
