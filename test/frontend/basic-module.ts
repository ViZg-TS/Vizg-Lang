import { log } from "console";

export function main(name: string) {
  let message = "hello " + name;
  log(message);
  return message;
}
