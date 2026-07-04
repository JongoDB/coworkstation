#!/usr/bin/env node

/**
 * Unit test for the vm-bench QmpClient against a mock QMP server.
 *
 * Exercises: greeting + capabilities negotiation, command execution,
 * error propagation, and event skipping. Prints "QMP-MOCK-OK" and
 * exits 0 on success; exits 1 with a message otherwise.
 */

const net = require('net');
const os = require('os');
const path = require('path');
const fs = require('fs');

const { QmpClient } = require(process.argv[2] ||
    '../../testbench/vm-bench-mcp.js');

function fail(msg) {
    console.error('FAIL: ' + msg);
    process.exit(1);
}

async function main() {
    const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'qmp-mock-'));
    const sockPath = path.join(dir, 'qmp.sock');
    const seen = [];

    const server = net.createServer((sock) => {
        // Real QMP greets immediately.
        sock.write(JSON.stringify({
            QMP: { version: { qemu: { major: 8 } }, capabilities: [] },
        }) + '\n');
        let buf = '';
        sock.on('data', (chunk) => {
            buf += chunk.toString('utf8');
            let idx;
            while ((idx = buf.indexOf('\n')) >= 0) {
                const line = buf.slice(0, idx);
                buf = buf.slice(idx + 1);
                if (!line.trim()) continue;
                const msg = JSON.parse(line);
                seen.push(msg.execute);
                if (msg.execute === 'qmp_capabilities') {
                    sock.write(JSON.stringify({ return: {} }) + '\n');
                } else if (msg.execute === 'screendump') {
                    // Interleave an async event; client must skip it.
                    sock.write(JSON.stringify({
                        event: 'NICE_EVENT', data: {},
                    }) + '\n');
                    sock.write(JSON.stringify({ return: {} }) + '\n');
                } else if (msg.execute === 'explode') {
                    sock.write(JSON.stringify({
                        error: { class: 'GenericError', desc: 'boom' },
                    }) + '\n');
                } else {
                    sock.write(JSON.stringify({ return: { ok: true } })
                        + '\n');
                }
            }
        });
    });
    await new Promise((r) => server.listen(sockPath, r));

    const client = new QmpClient(sockPath);
    const greeting = await client.connect(3000);
    if (!greeting.QMP) fail('greeting not surfaced');
    if (seen[0] !== 'qmp_capabilities') {
        fail('capabilities not negotiated first');
    }

    const dump = await client.execute('screendump', { filename: '/x' });
    if (typeof dump !== 'object') fail('screendump return not passed');

    const generic = await client.execute('query-status');
    if (!generic.ok) fail('return payload not unwrapped');

    let threw = false;
    try {
        await client.execute('explode');
    } catch (err) {
        threw = /boom/.test(err.message);
    }
    if (!threw) fail('QMP error not propagated');

    client.close();
    server.close();
    console.log('QMP-MOCK-OK');
    process.exit(0);
}

main().catch((err) => fail(err.message));
