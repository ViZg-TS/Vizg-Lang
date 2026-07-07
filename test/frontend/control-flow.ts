export function classify(value: number) {
  let label = "zero";

  if (value > 0) {
    label = "positive";
  } else {
    label = "negative";
  }

  while (value > 10) {
    value = value - 1;
  }

  return label;
}
