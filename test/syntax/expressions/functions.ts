let add = (left: number, right: number): number => left + right;
let identity = async value => value;
let named = function recurse(value) { return value ? recurse(value - 1) : value; };
let anonymous = async function (value) { return await value; };
function collect(prefix: string, ...items: string[]): string { return prefix + items[0]; }
