import value from "./static";

const direct = import("./dynamic");
const configured = import("./data.json", options);
const nested = consume(value ? import("./a") : import("./b"));

direct;
configured;
nested;
