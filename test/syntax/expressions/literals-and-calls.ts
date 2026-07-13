let array = [first, , ...rest, last];
let object = {
  key,
  [computed]: value,
  ...extra,
  method(item) { return item; },
  async load() { return await source; },
  get current() { return value; },
  set current(next) { value = next; },
};
let primitives = [null, true, false, 12.5, "text"];
let plain = `hello`;
let text = `hello ${user.name}`;
let pattern = /a[b\\/]c+/gi;
let division = total / count / 2;
let result = service?.items?.[0]?.run(...array)!;
let made = new Factory(result);
