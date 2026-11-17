import { createInterface } from "node:readline";

const supportedVersions = ["2025-11-25", "2025-06-18", "2025-03-26", "2024-11-05"];
const serverInfo = { name: "pc-power-switch", version: "1.0.0" };
const commandFeed = "pc-power-command";
const toolDefinition = {
  name: "request_pc_power_on",
  title: "Request PC power on",
  description:
    "Send exactly one 1-valued command to Adafruit IO, causing the ESP32 to pulse the motherboard PWR_SW optocoupler. PWR_SW is a toggle and this server cannot read the PC's power state. Use only when the user explicitly asks to turn the PC on and it is confirmed off; if state is unknown, ask first. Never retry an ambiguous or timed-out request until the PC state is checked. A successful response confirms Adafruit IO accepted the request, not that the PC booted.",
  inputSchema: {
    type: "object",
    properties: {},
    required: [],
    additionalProperties: false,
  },
};

const responsesById = new Map();

function send(message) {
  process.stdout.write(JSON.stringify(message) + "\n");
}

function rpcError(id, code, message) {
  return { jsonrpc: "2.0", id, error: { code, message } };
}

function toolResult(text, isError = false) {
  return { content: [{ type: "text", text }], isError };
}

async function requestPowerOn() {
  const username = process.env.ADAFRUIT_IO_USERNAME?.trim();
  const key = process.env.ADAFRUIT_IO_KEY?.trim();
  if (!username || !key) {
    return toolResult("Adafruit IO credentials are not configured. No command was sent.", true);
  }

  const url =
    "https://io.adafruit.com/api/v2/" +
    encodeURIComponent(username) +
    "/feeds/" +
    encodeURIComponent(commandFeed) +
    "/data";

  try {
    const response = await fetch(url, {
      method: "POST",
      headers: {
        "X-AIO-Key": key,
        "Content-Type": "application/json",
      },
      body: JSON.stringify({ value: "1" }),
      signal: AbortSignal.timeout(10000),
    });
    if (!response.ok) {
      return toolResult(
        "Adafruit IO returned HTTP " +
          response.status +
          "; the PC power state is not confirmed. Do not retry until the state is checked.",
        true,
      );
    }
    return toolResult("Adafruit IO accepted one power-on request. PC startup is not confirmed.");
  } catch {
    return toolResult(
      "The request failed or timed out, so delivery is uncertain. Check the PC state before retrying.",
      true,
    );
  }
}

async function handleMessage(message) {
  if (!message || message.jsonrpc !== "2.0" || typeof message.method !== "string") {
    if (message?.id !== undefined) send(rpcError(message.id, -32600, "Invalid JSON-RPC request."));
    return;
  }

  if (message.method === "notifications/initialized" || message.method.startsWith("notifications/")) {
    return;
  }
  if (message.id === undefined) return;

  if (message.method === "initialize") {
    const requested = message.params?.protocolVersion;
    send({
      jsonrpc: "2.0",
      id: message.id,
      result: {
        protocolVersion: supportedVersions.includes(requested) ? requested : supportedVersions[0],
        capabilities: { tools: {} },
        serverInfo,
      },
    });
    return;
  }

  if (message.method === "ping") {
    send({ jsonrpc: "2.0", id: message.id, result: {} });
    return;
  }

  if (message.method === "tools/list") {
    send({ jsonrpc: "2.0", id: message.id, result: { tools: [toolDefinition] } });
    return;
  }

  if (message.method === "tools/call") {
    if (message.params?.name !== toolDefinition.name) {
      send({
        jsonrpc: "2.0",
        id: message.id,
        result: toolResult("Unknown tool: " + String(message.params?.name ?? ""), true),
      });
      return;
    }

    const args = message.params?.arguments ?? {};
    if (!args || typeof args !== "object" || Array.isArray(args) || Object.keys(args).length !== 0) {
      send({
        jsonrpc: "2.0",
        id: message.id,
        result: toolResult("This tool accepts no arguments; no command was sent.", true),
      });
      return;
    }

    const idKey = JSON.stringify(message.id);
    let pending = responsesById.get(idKey);
    if (!pending) {
      pending = requestPowerOn();
      responsesById.set(idKey, pending);
      if (responsesById.size > 100) responsesById.delete(responsesById.keys().next().value);
    }
    send({ jsonrpc: "2.0", id: message.id, result: await pending });
    return;
  }

  send(rpcError(message.id, -32601, "Method not found."));
}

const input = createInterface({ input: process.stdin, crlfDelay: Infinity });
let queue = Promise.resolve();
input.on("line", (line) => {
  if (!line.trim()) return;
  queue = queue
    .then(() => handleMessage(JSON.parse(line)))
    .catch(() => {
      // Keep stdout reserved for MCP JSON-RPC messages and never log credentials.
    });
});
