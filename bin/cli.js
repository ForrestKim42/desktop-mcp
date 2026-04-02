#!/usr/bin/env node

const { execFileSync, spawn } = require("child_process");
const path = require("path");
const fs = require("fs");

const ROOT = path.resolve(__dirname, "..");

const BINARY_PATHS = [
  path.join(ROOT, ".build", "release", "desktop-pilot-mcp"),
  path.join(ROOT, ".build", "debug", "desktop-pilot-mcp"),
];

function findBinary() {
  for (const p of BINARY_PATHS) {
    if (fs.existsSync(p)) return p;
  }
  return null;
}

function build() {
  process.stderr.write("[desktop-pilot] Binary not found, building from source...\n");
  try {
    execFileSync("swift", ["build", "-c", "release"], {
      cwd: ROOT,
      stdio: ["ignore", "pipe", "pipe"],
    });
    process.stderr.write("[desktop-pilot] Build complete.\n");
  } catch (err) {
    process.stderr.write("[desktop-pilot] Build failed.\n");
    process.stderr.write("[desktop-pilot] Make sure Xcode Command Line Tools are installed:\n");
    process.stderr.write("[desktop-pilot]   xcode-select --install\n");
    process.exit(1);
  }
  return findBinary();
}

if (process.platform !== "darwin") {
  process.stderr.write("[desktop-pilot] Error: Desktop Pilot only supports macOS.\n");
  process.stderr.write("[desktop-pilot] Windows support is planned for a future release.\n");
  process.exit(1);
}

const binary = findBinary() || build();

if (!binary) {
  process.stderr.write("[desktop-pilot] Error: Could not find or build the binary.\n");
  process.exit(1);
}

const child = spawn(binary, process.argv.slice(2), {
  stdio: ["pipe", "pipe", "inherit"],
});

process.stdin.pipe(child.stdin);
child.stdout.pipe(process.stdout);

child.on("exit", (code) => process.exit(code || 0));

process.on("SIGINT", () => child.kill("SIGINT"));
process.on("SIGTERM", () => child.kill("SIGTERM"));
