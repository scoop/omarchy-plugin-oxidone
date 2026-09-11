module.exports = [
  {
    files: ["src/**/*.js"],
    languageOptions: {
      ecmaVersion: 2022,
      sourceType: "commonjs",
      globals: { module: "writable", console: "readonly" },
    },
    rules: {
      eqeqeq: "error",
      "no-var": "off",
      "prefer-const": "off",
    },
  },
  {
    files: ["test/**/*.js"],
    languageOptions: {
      ecmaVersion: 2022,
      sourceType: "module",
      globals: { console: "readonly" },
    },
    rules: {
      eqeqeq: "error",
      "no-var": "off",
      "prefer-const": "off",
    },
  },
];
