const colors = {
  red: "\x1b[31m",
  green: "\x1b[32m",
  yellow: "\x1b[33m",
  blue: "\x1b[34m",
  magenta: "\x1b[35m",
  cyan: "\x1b[36m",
  white: "\x1b[37m",
  reset: "\x1b[0m"
};

export default function createColorArt() {
  const art = [
    "╔══════════════════════╗",
    "║ 🎨 Colorful Art! 🎨 ║",
    "╠══════════════════════╣",
    "║ ▓███████▓  ▀▄▄▀     ║",
    "║ █▓████▓█  ▀▀▄▄    ▀ ║",
    "║ █▓▀▄▄▀▓█  ▀▄▄▄▀▀   ║",
    "║ ▀▄▀▀▄▄▀▀  ▀▀▄▄▀▀   ║",
    "╚══════════════════════╝"
  ];

  for (let i: number = 0; i < art.length; i++) {
    let line = "";
    for (let j = 0; j < art[i]!.length; j++) {
      line += `${(colors as any)[i % colors.red.length] || ""}${art[i]![j]}${colors.reset}`;
    }
    hostLogger.log(line);
  }

  return art;
}
