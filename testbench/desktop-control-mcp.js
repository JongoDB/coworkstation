#!/usr/bin/env node

/**
 * Desktop-control MCP server — Tier 2 of the appliance test bench.
 *
 * Lets Claude drive GUI apps on a DISPOSABLE nested X display (Xvfb),
 * never the member's real session: every tool except display_start
 * refuses to run until this server has created its own display, and
 * the display is torn down (with every app it launched) on
 * display_stop or exit.
 *
 * Transport: MCP stdio — newline-delimited JSON-RPC 2.0.
 * Dependencies: none (Node core only). External binaries: Xvfb,
 * xdotool, imagemagick (`import`), optionally python3-pyatspi for
 * ax_tree. testbench/setup.sh installs them.
 *
 * Design: docs/design.md (test bench section)
 */

const fs = require('fs');
const readline = require('readline');
const { spawn, execFile } = require('child_process');

const SERVER_INFO = { name: 'appliance-desktop-control', version: '0.1.0' };
const PROTOCOL_FALLBACK = '2024-11-05';
const DISPLAY_MIN = 50;
const DISPLAY_MAX = 99;
const SCREENSHOT_MAX_BYTES = 32 * 1024 * 1024;

// ============================================================
// Nested display state
// ============================================================

const state = {
    display: null,      // ":NN" once display_start succeeds
    xvfb: null,         // Xvfb child process
    children: [],       // processes launched onto the display
};

function findFreeDisplay() {
    for (let n = DISPLAY_MIN; n <= DISPLAY_MAX; n++) {
        if (!fs.existsSync(`/tmp/.X${n}-lock`) &&
            !fs.existsSync(`/tmp/.X11-unix/X${n}`)) {
            return n;
        }
    }
    return null;
}

function waitForSocket(n, timeoutMs) {
    return new Promise((resolve, reject) => {
        const started = Date.now();
        const timer = setInterval(() => {
            if (fs.existsSync(`/tmp/.X11-unix/X${n}`)) {
                clearInterval(timer);
                resolve();
            } else if (Date.now() - started > timeoutMs) {
                clearInterval(timer);
                reject(new Error(`Xvfb :${n} did not come up`));
            }
        }, 100);
    });
}

function displayEnv() {
    return Object.assign({}, process.env, { DISPLAY: state.display });
}

function requireDisplay() {
    if (!state.display) {
        throw new Error(
            'no test display: call display_start first ' +
            '(this server never controls an existing session)');
    }
}

function execTool(cmd, args, opts) {
    return new Promise((resolve, reject) => {
        execFile(cmd, args, Object.assign({
            env: displayEnv(),
            maxBuffer: SCREENSHOT_MAX_BYTES,
        }, opts || {}), (err, stdout) => {
            if (err) {
                reject(new Error(`${cmd} failed: ${err.message}`));
            } else {
                resolve(stdout);
            }
        });
    });
}

// ============================================================
// Tools
// ============================================================

async function toolDisplayStart(args) {
    if (state.display) {
        return textResult(`display already running: ${state.display}`);
    }
    const width = Number(args.width) || 1280;
    const height = Number(args.height) || 800;
    const n = findFreeDisplay();
    if (n === null) {
        throw new Error('no free display number in the test range');
    }
    state.xvfb = spawn('Xvfb', [
        `:${n}`, '-screen', '0', `${width}x${height}x24`,
        '-nolisten', 'tcp',
    ], { stdio: 'ignore' });
    state.xvfb.on('exit', () => {
        if (state.display === `:${n}`) {
            state.display = null;
            state.xvfb = null;
        }
    });
    await waitForSocket(n, 5000);
    state.display = `:${n}`;
    return textResult(`started nested display ${state.display} ` +
        `(${width}x${height})`);
}

async function toolDisplayStop() {
    if (!state.display) {
        return textResult('no display running');
    }
    for (const child of state.children) {
        try { process.kill(-child.pid, 'SIGTERM'); } catch (e) { /* gone */ }
        try { child.kill('SIGKILL'); } catch (e) { /* gone */ }
    }
    state.children = [];
    const stopped = state.display;
    if (state.xvfb) {
        state.xvfb.kill('SIGTERM');
        state.xvfb = null;
    }
    state.display = null;
    return textResult(`stopped ${stopped} and its processes`);
}

async function toolScreenshot() {
    requireDisplay();
    const png = await execTool('import',
        ['-window', 'root', 'png:-'], { encoding: 'buffer' });
    if (!png || png.length === 0) {
        throw new Error('screenshot produced no data');
    }
    return {
        content: [{
            type: 'image',
            data: Buffer.from(png).toString('base64'),
            mimeType: 'image/png',
        }],
    };
}

async function toolClick(args) {
    requireDisplay();
    const x = Number(args.x);
    const y = Number(args.y);
    if (!Number.isFinite(x) || !Number.isFinite(y)) {
        throw new Error('click needs numeric x and y');
    }
    const button = String(args.button || 1);
    if (!/^[1-5]$/.test(button)) {
        throw new Error('button must be 1-5');
    }
    await execTool('xdotool',
        ['mousemove', String(x), String(y), 'click', button]);
    return textResult(`clicked button ${button} at ${x},${y}`);
}

async function toolType(args) {
    requireDisplay();
    if (typeof args.text !== 'string' || args.text.length === 0) {
        throw new Error('type needs a non-empty text string');
    }
    await execTool('xdotool',
        ['type', '--delay', '12', '--', args.text]);
    return textResult(`typed ${args.text.length} characters`);
}

async function toolKey(args) {
    requireDisplay();
    if (typeof args.keys !== 'string' ||
        !/^[A-Za-z0-9_+]+$/.test(args.keys)) {
        throw new Error(
            'keys must be an xdotool keysym combo like ctrl+shift+t');
    }
    await execTool('xdotool', ['key', '--', args.keys]);
    return textResult(`sent key ${args.keys}`);
}

async function toolLaunch(args) {
    requireDisplay();
    if (typeof args.command !== 'string' || args.command.length === 0) {
        throw new Error('launch needs a command string');
    }
    const argv = args.args || [];
    if (!Array.isArray(argv) || argv.some((a) => typeof a !== 'string')) {
        throw new Error('args must be an array of strings');
    }
    // argv-array spawn, no shell: metacharacters are inert by design.
    const child = spawn(args.command, argv, {
        env: displayEnv(),
        stdio: 'ignore',
        detached: true,
    });
    await new Promise((resolve, reject) => {
        child.once('spawn', resolve);
        child.once('error', (err) => reject(
            new Error(`launch failed: ${err.message}`)));
    });
    state.children.push(child);
    return textResult(`launched ${args.command} (pid ${child.pid})`);
}

async function toolAxTree() {
    requireDisplay();
    const script = [
        'import pyatspi',
        'def walk(a, d=0):',
        '    print("  " * d + f"{a.getRoleName()}: {a.name!r}")',
        '    for c in a: walk(c, d + 1)',
        'walk(pyatspi.Registry.getDesktop(0))',
    ].join('\n');
    try {
        const out = await execTool('python3', ['-c', script]);
        return textResult(String(out) || '(empty accessibility tree)');
    } catch (err) {
        return textResult(
            'AT-SPI tree unavailable (install python3-pyatspi and ' +
            'at-spi2-core): ' + err.message);
    }
}

const TOOLS = {
    display_start: {
        description: 'Start a disposable nested X display (Xvfb) that ' +
            'later tools operate on. Never touches an existing session.',
        inputSchema: {
            type: 'object',
            properties: {
                width: { type: 'number', description: 'default 1280' },
                height: { type: 'number', description: 'default 800' },
            },
        },
        handler: toolDisplayStart,
    },
    display_stop: {
        description: 'Stop the nested display and every app launched ' +
            'onto it.',
        inputSchema: { type: 'object', properties: {} },
        handler: toolDisplayStop,
    },
    screenshot: {
        description: 'PNG screenshot of the nested display.',
        inputSchema: { type: 'object', properties: {} },
        handler: toolScreenshot,
    },
    click: {
        description: 'Move the pointer and click on the nested display.',
        inputSchema: {
            type: 'object',
            properties: {
                x: { type: 'number' },
                y: { type: 'number' },
                button: { type: 'number', description: '1=left (default)' },
            },
            required: ['x', 'y'],
        },
        handler: toolClick,
    },
    type: {
        description: 'Type literal text into the focused window.',
        inputSchema: {
            type: 'object',
            properties: { text: { type: 'string' } },
            required: ['text'],
        },
        handler: toolType,
    },
    key: {
        description: 'Send a keysym combo (xdotool syntax, e.g. Return, ' +
            'ctrl+s).',
        inputSchema: {
            type: 'object',
            properties: { keys: { type: 'string' } },
            required: ['keys'],
        },
        handler: toolKey,
    },
    launch: {
        description: 'Launch a GUI application onto the nested display ' +
            '(argv array, no shell).',
        inputSchema: {
            type: 'object',
            properties: {
                command: { type: 'string' },
                args: { type: 'array', items: { type: 'string' } },
            },
            required: ['command'],
        },
        handler: toolLaunch,
    },
    ax_tree: {
        description: 'Dump the AT-SPI accessibility tree of the nested ' +
            'display (role names + labels) for robust element location.',
        inputSchema: { type: 'object', properties: {} },
        handler: toolAxTree,
    },
};

function textResult(text) {
    return { content: [{ type: 'text', text: text }] };
}

// ============================================================
// MCP plumbing (newline-delimited JSON-RPC 2.0 over stdio)
// ============================================================

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
            break; // notification, no reply
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
    rl.on('close', () => {
        toolDisplayStop().then(() => process.exit(0));
    });
    process.on('SIGTERM', () => {
        toolDisplayStop().then(() => process.exit(0));
    });
}

if (require.main === module) {
    main();
}

module.exports = { TOOLS, findFreeDisplay };
