function* values(source: number) {
  yield;
  yield source;
  yield* values(source);
}

const asyncValues = async function* () {
  yield 1;
};

class Stream {
  *items() { yield 2; }
  async *more() { yield* values(3); }
}

const stream = {
  *items() { yield 4; },
  async *more() { yield* values(5); },
};
