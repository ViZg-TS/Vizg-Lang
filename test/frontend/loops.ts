export function sum(limit: number) {
  let total = 0;

  for (let i = 0; i < limit; i = i + 1) {
    total = total + i;
  }

  return total;
}
