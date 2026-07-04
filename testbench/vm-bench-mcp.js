#!/usr/bin/env node

/**
 * vm-bench MCP server — Tier 3 of the appliance test bench.
 *
 * STATUS: EXPERIMENTAL. The QMP wire protocol is unit-tested against
 * a mock socket; end-to-end behavior against a real (licensed) guest
 * is on the hardware-verify checklist in
 * docs/phases.md.
 *
 * Drives disposable QEMU/KVM guests (e.g. a Windows test image) for
 * cross-OS app testing: boot from a snapshot, screenshot the console,
 * inject input, revert, stop. The member's Cowork VM stack is
 * untouched — this server manages its own guests under
 * ~/.local/share/coworkstation/vm-bench/.
 *
 * Transport: MCP stdio — newline-delimited JSON-RPC 2.0.
 * Dependencies: none (Node core only). External: qemu-system-*.
 */

const fs = require('fs');
const net = require('net');
const os = require('os');
const path = require('path');
const readline = require('readline');
const { spawn } = require('child_process');

const SERVER_INFO = { name: 'appliance-vm-bench', version: '0.1.0' };
const PROTOCOL_FALLBACK = '2024-11-05';
const EXPERIMENTAL = '[experimental] ';

const BENCH_DIR = path.join(
    os.homedir(), '.local', 'share', 'coworkstation', 'vm-bench');

// ============================================================
// QMP client (newline-delimited JSON over a Unix socket)
// ============================================================

class QmpClient {
    constructor(socketPath) {
        this.socketPath = socketPath;
        this.socket = null;
        this.pending = [];
        this.buffer = '';
        this.greeting = null;
    }

    connect(timeoutMs) {
        return new Promise((resolve, reject) => {
            const sock = net.createConnection(this.socketPath);
            const timer = setTimeout(() => {
                sock.destroy();
                reject(new Error('QMP connect timeout'));
            }, timeoutMs || 5000);
            sock.on('error', (err) => {
                clearTimeout(timer);
                reject(err);
            });
            sock.on('data', (chunk) => this._onData(chunk));
            this.socket = sock;
            // First message is the greeting; then we negotiate.
            this.pending.push({
                resolve: (msg) => {
                    clearTimeout(timer);
                    this.greeting = msg;
                    this.execute('qmp_capabilities')
                        .then(() => resolve(msg))
                        .catch(reject);
                },
                reject: reject,
                greeting: true,
            });
        });
    }

    _onData(chunk) {
        this.buffer += chunk.toString('utf8');
        let idx;
        while ((idx = this.buffer.indexOf('\n')) >= 0) {
            const line = this.buffer.slice(0, idx).trim();
            this.buffer = this.buffer.slice(idx + 1);
            if (!line) continue;
            let msg;
            try {
                msg = JSON.parse(line);
            } catch (err) {
                continue;
            }
            if (msg.event) continue; // async events: not awaited here
            const waiter = this.pending.shift();
            if (!waiter) continue;
            if (msg.error && !waiter.greeting) {
                waiter.reject(new Error(msg.error.desc || 'QMP error'));
            } else {
                waiter.resolve(waiter.greeting ? msg : msg.return);
            }
        }
    }

    execute(command, args) {
        return new Promise((resolve, reject) => {
            if (!this.socket) {
                reject(new Error('QMP not connected'));
                return;
            }
            this.pending.push({ resolve: resolve, reject: reject });
            const payload = { execute: command };
            if (args) payload.arguments = args;
            this.socket.write(JSON.stringify(payload) + '\n');
        });
    }

    close() {
        if (this.socket) {
            this.socket.destroy();
            this.socket = null;
        }
    }
}

// ============================================================
// Guest lifecycle
// ============================================================

const vm = {
    proc: null,
    qmp: null,
    dir: null,
};

function qemuBinary() {
    return process.arch === 'arm64'
        ? 'qemu-system-aarch64'
        : 'qemu-system-x86_64';
}

async function toolVmStart(args) {
    if (vm.proc) {
        throw new Error('a guest is already running; vm_stop first');
    }
    if (typeof args.image !== 'string' || !fs.existsSync(args.image)) {
        throw new Error('image must be a path to an existing disk image');
    }
    const memory = String(Number(args.memoryGB) || 4);
    fs.mkdirSync(BENCH_DIR, { recursive: true });
    vm.dir = fs.mkdtempSync(path.join(BENCH_DIR, 'guest-'));
    const qmpSock = path.join(vm.dir, 'qmp.sock');

    const argv = [
        '-m', `${memory}G`,
        '-snapshot', // never write to the base image
        '-drive', `file=${args.image},if=virtio`,
        '-qmp', `unix:${qmpSock},server,nowait`,
        '-display', 'none',
        '-vga', 'std',
    ];
    if (fs.existsSync('/dev/kvm')) {
        argv.unshift('-enable-kvm', '-cpu', 'host');
    }
    if (typeof args.snapshot === 'string' && args.snapshot.length > 0) {
        argv.push('-loadvm', args.snapshot);
    }

    vm.proc = spawn(qemuBinary(), argv, { stdio: 'ignore' });
    vm.proc.on('exit', () => {
        vm.proc = null;
        if (vm.qmp) {
            vm.qmp.close();
            vm.qmp = null;
        }
    });

    // Wait for the QMP socket, then negotiate.
    const started = Date.now();
    while (!fs.existsSync(qmpSock)) {
        if (!vm.proc) throw new Error('qemu exited during startup');
        if (Date.now() - started > 15000) {
            throw new Error('QMP socket never appeared');
        }
        await new Promise((r) => setTimeout(r, 200));
    }
    vm.qmp = new QmpClient(qmpSock);
    await vm.qmp.connect(10000);
    return textResult(
        `guest started (qemu ${qemuBinary()}, ${memory}G, ` +
        'base image copy-on-write via -snapshot)');
}

async function toolVmScreenshot() {
    requireGuest();
    const shot = path.join(vm.dir, 'screen.ppm');
    await vm.qmp.execute('screendump', { filename: shot });
    const data = fs.readFileSync(shot);
    fs.unlinkSync(shot);
    return {
        content: [{
            type: 'image',
            data: data.toString('base64'),
            mimeType: 'image/x-portable-pixmap',
        }],
    };
}

async function toolVmInput(args) {
    requireGuest();
    if (!Array.isArray(args.events) || args.events.length === 0) {
        throw new Error(
            'events must be a non-empty array of QMP InputEvent objects');
    }
    await vm.qmp.execute('input-send-event', { events: args.events });
    return textResult(`sent ${args.events.length} input event(s)`);
}

async function toolVmRevert(args) {
    requireGuest();
    if (typeof args.snapshot !== 'string' || args.snapshot.length === 0) {
        throw new Error('snapshot name required');
    }
    // loadvm has no direct QMP command; goes via the human monitor.
    const out = await vm.qmp.execute('human-monitor-command',
        { 'command-line': `loadvm ${args.snapshot}` });
    if (out && String(out).trim().length > 0) {
        throw new Error(`loadvm: ${String(out).trim()}`);
    }
    return textResult(`reverted to snapshot '${args.snapshot}'`);
}

async function toolVmStop() {
    if (!vm.proc) {
        return textResult('no guest running');
    }
    try {
        await vm.qmp.execute('quit');
    } catch (err) {
        vm.proc.kill('SIGKILL');
    }
    return textResult('guest stopped');
}

function requireGuest() {
    if (!vm.proc || !vm.qmp) {
        throw new Error('no guest running: call vm_start first');
    }
}

const TOOLS = {
    vm_start: {
        description: EXPERIMENTAL + 'Boot a disposable QEMU guest from ' +
            'a base image (copy-on-write; the image is never modified). ' +
            'Optionally resume a named snapshot.',
        inputSchema: {
            type: 'object',
            properties: {
                image: { type: 'string', description: 'disk image path' },
                snapshot: { type: 'string' },
                memoryGB: { type: 'number', description: 'default 4' },
            },
            required: ['image'],
        },
        handler: toolVmStart,
    },
    vm_screenshot: {
        description: EXPERIMENTAL + 'Screenshot the guest console (PPM).',
        inputSchema: { type: 'object', properties: {} },
        handler: toolVmScreenshot,
    },
    vm_input: {
        description: EXPERIMENTAL + 'Send raw QMP InputEvents (keys, ' +
            'pointer) to the guest.',
        inputSchema: {
            type: 'object',
            properties: { events: { type: 'array' } },
            required: ['events'],
        },
        handler: toolVmInput,
    },
    vm_revert: {
        description: EXPERIMENTAL + 'Revert the guest to a named ' +
            'internal snapshot.',
        inputSchema: {
            type: 'object',
            properties: { snapshot: { type: 'string' } },
            required: ['snapshot'],
        },
        handler: toolVmRevert,
    },
    vm_stop: {
        description: EXPERIMENTAL + 'Stop the guest and discard its ' +
            'copy-on-write state.',
        inputSchema: { type: 'object', properties: {} },
        handler: toolVmStop,
    },
};

function textResult(text) {
    return { content: [{ type: 'text', text: text }] };
}

// ============================================================
// MCP plumbing (same shape as desktop-control-mcp.js)
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
    rl.on('close', () => {
        toolVmStop().then(() => process.exit(0));
    });
    process.on('SIGTERM', () => {
        toolVmStop().then(() => process.exit(0));
    });
}

if (require.main === module) {
    main();
}

module.exports = { QmpClient, TOOLS };
