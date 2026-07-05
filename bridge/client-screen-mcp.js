#!/usr/bin/env node

/**
 * client-screen MCP server — hands Claude the CLIENT device's shared
 * screen, when (and only when) the user is actively sharing it via
 * the bridge page.
 *
 * Reads the latest frame the bridge server keeps in the user's
 * runtime dir (tmpfs — nothing persists) and refuses stale frames,
 * so Claude can never see a screen the user stopped sharing.
 *
 * Transport: MCP stdio — newline-delimited JSON-RPC 2.0 (same shape
 * as the testbench servers). Node core only.
 */

const fs = require('fs');
const path = require('path');
const readline = require('readline');

const SERVER_INFO = { name: 'cws-client-screen', version: '0.1.0' };
const PROTOCOL_FALLBACK = '2024-11-05';
const RUNTIME_DIR = process.env.CWS_BRIDGE_RUNTIME_DIR ||
    path.join(process.env.XDG_RUNTIME_DIR || '/tmp', 'cws-bridge');
const MAX_AGE_MS = 20 * 1000;

function frameMeta() {
    try {
        return JSON.parse(fs.readFileSync(
            path.join(RUNTIME_DIR, 'latest.meta'), 'utf8'));
    } catch (err) {
        return null;
    }
}

async function toolScreenshot() {
    const meta = frameMeta();
    if (!meta) {
        throw new Error('no client screen is being shared — ask the ' +
            'user to open the bridge page and press "Start screen share"');
    }
    const age = Date.now() - meta.ts;
    if (age > MAX_AGE_MS) {
        throw new Error(`client screen share looks stopped (last frame ` +
            `${Math.round(age / 1000)}s ago) — ask the user to restart it`);
    }
    const jpg = fs.readFileSync(path.join(RUNTIME_DIR, 'latest.jpg'));
    return {
        content: [{
            type: 'image',
            data: jpg.toString('base64'),
            mimeType: 'image/jpeg',
        }],
    };
}

async function toolInfo() {
    const meta = frameMeta();
    const text = meta
        ? `sharing active; last frame ${Date.now() - meta.ts}ms ago, ` +
          `${meta.bytes} bytes`
        : 'no active client screen share';
    return { content: [{ type: 'text', text: text }] };
}

const TOOLS = {
    client_screenshot: {
        description: 'Screenshot of the CLIENT device\'s screen, if the ' +
            'user is actively sharing it via the Coworkstation bridge ' +
            'page. Errors when nothing is shared — never guesses.',
        inputSchema: { type: 'object', properties: {} },
        handler: toolScreenshot,
    },
    client_screen_info: {
        description: 'Whether a client screen share is active and how ' +
            'fresh the latest frame is.',
        inputSchema: { type: 'object', properties: {} },
        handler: toolInfo,
    },
};

function send(msg) {
    process.stdout.write(JSON.stringify(msg) + '\n');
}
function replyResult(id, result) {
    send({ jsonrpc: '2.0', id: id, result: result });
}
function replyError(id, code, message) {
    send({ jsonrpc: '2.0', id: id, error: { code: code, message: message } });
}

async function handle(msg) {
    const id = msg.id;
    switch (msg.method) {
        case 'initialize':
            replyResult(id, {
                protocolVersion:
                    (msg.params && msg.params.protocolVersion) ||
                    PROTOCOL_FALLBACK,
                capabilities: { tools: {} },
                serverInfo: SERVER_INFO,
            });
            break;
        case 'notifications/initialized':
            break;
        case 'ping':
            replyResult(id, {});
            break;
        case 'tools/list':
            replyResult(id, {
                tools: Object.keys(TOOLS).map((name) => ({
                    name: name,
                    description: TOOLS[name].description,
                    inputSchema: TOOLS[name].inputSchema,
                })),
            });
            break;
        case 'tools/call': {
            const name = msg.params && msg.params.name;
            const tool = TOOLS[name];
            if (!tool) {
                replyError(id, -32602, `unknown tool '${name}'`);
                break;
            }
            try {
                const result = await tool.handler(
                    (msg.params && msg.params.arguments) || {});
                replyResult(id, result);
            } catch (err) {
                replyResult(id, {
                    content: [{ type: 'text', text: String(err.message) }],
                    isError: true,
                });
            }
            break;
        }
        default:
            if (id !== undefined) {
                replyError(id, -32601, `unknown method '${msg.method}'`);
            }
    }
}

function main() {
    const rl = readline.createInterface({ input: process.stdin });
    rl.on('line', (line) => {
        if (!line.trim()) return;
        let msg;
        try {
            msg = JSON.parse(line);
        } catch (err) {
            replyError(null, -32700, 'parse error');
            return;
        }
        handle(msg).catch((err) => {
            if (msg.id !== undefined) {
                replyError(msg.id, -32603, String(err.message));
            }
        });
    });
}

main();
