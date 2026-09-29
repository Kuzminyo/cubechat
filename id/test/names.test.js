import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import test from 'node:test';
import { nameProblem, normalizeName } from '../src/names.js';

const cases = JSON.parse(readFileSync(new URL('./fixtures/name-cases.json', import.meta.url)));

for (const c of cases) {
  test(`name case ${JSON.stringify(c.input)}`, () => {
    const name = normalizeName(c.input);
    assert.equal(name, c.name);
    assert.equal(nameProblem(name), c.problem);
  });
}
