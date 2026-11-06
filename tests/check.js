// Syntax + ASCII check for every .lua file, then run a Lua test file in fengari.
// Usage: node check.js <pluginDir> [testFile.lua]
const fs = require('fs');
const path = require('path');
const luaparse = require('luaparse');

const pluginDir = path.resolve(process.argv[2]);
let bad = 0;
function walk(dir) {
  for (const name of fs.readdirSync(dir)) {
    const p = path.join(dir, name);
    if (fs.statSync(p).isDirectory()) walk(p);
    else if (p.endsWith('.lua')) {
      const src = fs.readFileSync(p, 'utf8');
      try { luaparse.parse(src, { luaVersion: '5.3' }); } catch (e) { bad++; console.log('SYNTAX', p, e.message); }
      const lines = src.split('\n');
      lines.forEach((l, i) => { if (/[^\x00-\x7f]/.test(l)) { bad++; console.log('NON-ASCII', p + ':' + (i + 1), l); } });
    }
  }
}
walk(pluginDir);
console.log(bad === 0 ? 'syntax + ascii OK' : bad + ' problems');

const testFile = process.argv[3];
if (testFile) {
  const { lua, lauxlib, lualib, to_luastring } = require('fengari');
  const L = lauxlib.luaL_newstate();
  lualib.luaL_openlibs(L);
  const setup = `package.path = ${JSON.stringify(pluginDir.replace(/\\/g, '/') + '/?.lua')}`;
  lauxlib.luaL_dostring(L, to_luastring(setup));
  const status = lauxlib.luaL_dofile(L, to_luastring(path.resolve(testFile).replace(/\\/g, '/')));
  if (status !== lua.LUA_OK) {
    console.log('LUA ERROR:', lua.lua_tojsstring(L, -1));
    process.exit(1);
  }
}
process.exit(bad === 0 ? 0 : 1);
