module.exports = {
  testEnvironment: "node",
  testMatch: ["**/test/**/*.test.js"],
  collectCoverageFrom: [
    "functions/**/*.js",
    "!functions/node_modules/**",
    "!functions/.env*",
  ],
  coverageDirectory: "coverage",
  verbose: true,
};
