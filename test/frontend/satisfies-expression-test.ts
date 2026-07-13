interface Config {
  enabled: boolean;
}

const value = { enabled: true };
const config = value satisfies Config;
const chained = value as Config satisfies Config;
const reverse = value satisfies Config as Config;

const satisfies = config;
satisfies;
