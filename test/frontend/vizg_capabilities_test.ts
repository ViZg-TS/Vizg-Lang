/*
  vizg capabilities smoke test.

  This file is intentionally limited to the frontend features currently implemented:
  - comments
  - named/default imports
  - let/const/var declarations
  - exported variable declarations
  - exported and non-exported functions
  - typed parameters
  - string/number/boolean/null literals
  - binary expressions
  - assignments
  - calls
  - member expressions
  - if/else
  - while
  - for
  - return
  - named exports
  - aliased exports
*/

import defaultLogger from "console";
import { log, warn } from "console";

// Global declarations.
let localCounter = 0;
let localName = "dev";
let localEnabled = true;
let localMissing = null;

// Exported variable declarations.
export let featureFlag = true;
export const version = "0.1.0";
export var mutableTotal = 0;

// Non-exported function, exported later through an alias.
function makeGreeting(name: string) {
  let prefix = "hello ";
  let message = prefix + name;

  log(message);

  return message;
}

// Exported function with if/else, assignment, while, and binary expressions.
export function classify(value: number) {
  let label = "zero";

  if (value > 0) {
    label = "positive";
  } else {
    label = "negative";
  }

  while (value > 10) {
    let nextValue = value - 1;
    value = nextValue;
  }

  return label;
}

// Exported function with for loop.
// The current parser accepts the for header but keeps the CFG/AST simple.
export function sum(limit: number) {
  let total = 0;

  for (let i = 0; i < limit; i = i + 1) {
    let nextTotal = total + limit;
    total = nextTotal;
  }

  return total;
}

// Exported function with calls, member access, assignment and return expression.
export function run(name: string) {
  let greeting = makeGreeting(name);
  let state = classify(localCounter);

  mutableTotal = sum(3);

  defaultLogger.log(greeting);
  warn(state);

  return greeting + state;
}

// Named exports and aliased exports.
// These must not duplicate exported names above.
export { localCounter };
export { localName as exportedName };
export { makeGreeting as greetAlias };
