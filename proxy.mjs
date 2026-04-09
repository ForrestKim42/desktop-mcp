#!/usr/bin/env node

import { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js";
import { StdioServerTransport } from "@modelcontextprotocol/sdk/server/stdio.js";
import { spawn } from "child_process";
import { fileURLToPath } from "url";
import { dirname, join } from "path";
import { appendFileSync } from "fs";
import { z } from "zod";

const LOG = "/tmp/desktop-mcp-proxy.log";
const log = (msg) => appendFileSync(LOG, `${new Date().toISOString()} ${msg}\n`);

const __dirname = dirname(fileURLToPath(import.meta.url));
const BINARY = join(__dirname, ".build", "release", "desktop-pilot-mcp");

const child = spawn(BINARY, [], { stdio: ["pipe", "pipe", "pipe"] });
child.stderr.on("data", (d) => log(`[swift] ${d.toString().trim()}`));

let msgId = 0;
const pending = new Map();
let buf = Buffer.alloc(0);  // Use Buffer, not string — Content-Length is byte length

child.stdout.on("data", (chunk) => {
  buf = Buffer.concat([buf, chunk]);
  while (true) {
    // Find \r\n\r\n header separator
    const sepIdx = buf.indexOf("\r\n\r\n");
    if (sepIdx < 0) break;
    const header = buf.slice(0, sepIdx).toString();
    const match = header.match(/Content-Length:\s*(\d+)/i);
    if (!match) { buf = buf.slice(sepIdx + 4); continue; }
    const contentLength = parseInt(match[1]);
    const bodyStart = sepIdx + 4;
    if (buf.length < bodyStart + contentLength) break;  // Wait for more data
    const body = buf.slice(bodyStart, bodyStart + contentLength).toString("utf8");
    buf = buf.slice(bodyStart + contentLength);
    try {
      const msg = JSON.parse(body);
      log(`[parsed] id=${msg.id}`);
      if (msg.id !== undefined && pending.has(msg.id)) {
        pending.get(msg.id)(msg);
        pending.delete(msg.id);
      }
    } catch (e) {
      log(`[error] ${e.message}`);
    }
  }
});

function sendToSwift(method, params) {
  return new Promise((resolve, reject) => {
    const id = ++msgId;
    const msg = JSON.stringify({ jsonrpc: "2.0", id, method, params });
    const msgBuf = Buffer.from(msg, "utf8");
    const header = `Content-Length: ${msgBuf.length}\r\n\r\n`;
    pending.set(id, resolve);
    child.stdin.write(header);
    child.stdin.write(msgBuf);
    log(`[send] id=${id} method=${method}`);
    setTimeout(() => {
      if (pending.has(id)) {
        pending.delete(id);
        log(`[timeout] id=${id}`);
        reject(new Error("Timeout"));
      }
    }, 120000);
  });
}

// Initialize Swift binary
log("[init] starting swift handshake");
await sendToSwift("initialize", {
  protocolVersion: "2024-11-05",
  capabilities: {},
  clientInfo: { name: "proxy", version: "1.0" },
});
log("[init] handshake done");

const notif = JSON.stringify({ jsonrpc: "2.0", method: "notifications/initialized" });
const notifBuf = Buffer.from(notif, "utf8");
child.stdin.write(`Content-Length: ${notifBuf.length}\r\n\r\n`);
child.stdin.write(notifBuf);
log("[init] sent notifications/initialized");

// MCP Server
const server = new McpServer({ name: "desktop-mcp", version: "1.0.0" });

server.tool(
  "desktop_do",
  `Control any macOS app via accessibility using a path grammar.

A path is a slash-joined sequence of segments. Segments are either an app name, a ref (TYPE:Label[@N]), or a verb (tap, type:<text>, press:<key>, find:<query>, expect:<name>, wait:<ms>, scroll:<dir>).

A trailing '?' dumps the end-state view for that path; '!' is assert-only; no marker means silent ok/error. 'paths' is a JSON array — one view block per path.

Examples:
  desktop_do({ paths: ["Slack?"] })                         — read Slack
  desktop_do({ paths: ["Slack/find:닫기/tap"] })             — search and act
  desktop_do({ paths: [
    "Slack/channel-sidebar-channel:alpha-room/tap",
    "Slack/Input:message_input/type:hello/press:RETURN?"
  ]})                                                        — batched flow

Full grammar + design rationale: docs/PATH_API.md.`,
  {
    app: z.string().optional().describe("Default app name or bundle ID. Omit for frontmost. A path's first segment can override this per-path."),
    window: z.string().optional().describe("Target window title for background interaction. Only this window gets full-depth snapshot."),
    paths: z.array(z.string()).optional().describe("Array of path strings. Each path is evaluated independently and returns one view block. Omit to read the default app's root."),
  },
  async ({ app, window, paths }) => {
    log(`[tool] desktop_do app=${app} window=${window} paths=${JSON.stringify(paths)}`);
    const args = {};
    if (app) args.app = app;
    if (window) args.window = window;
    if (paths) args.paths = paths;

    try {
      const response = await sendToSwift("tools/call", {
        name: "desktop_do",
        arguments: args,
      });
      log(`[tool] response ok`);

      const result = response.result || {};
      const content = result.content || [];
      return {
        content: content.map((c) => {
          if (c.type === "image") return { type: "image", data: c.data, mimeType: c.mimeType };
          return { type: "text", text: c.text || "" };
        }),
        isError: result.isError || false,
      };
    } catch (e) {
      log(`[tool] error: ${e.message}`);
      return { content: [{ type: "text", text: `Error: ${e.message}` }], isError: true };
    }
  }
);

const transport = new StdioServerTransport();
await server.connect(transport);
log("[init] MCP server connected to stdio");

process.on("exit", () => child.kill());
process.on("SIGINT", () => { child.kill(); process.exit(); });
process.on("SIGTERM", () => { child.kill(); process.exit(); });
