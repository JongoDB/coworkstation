#!/usr/bin/env node

/**
 * Minimal MCP stdio test client for the appliance test-bench servers.
 *
 * Usage: node mcp-client.js <server.js> <requests.jsonl>
 *
 * Sends each JSON-RPC request from the file in order, waiting for a
 * response to each request that has an id before sending the next.
 * Responses are printed one per line to stdout. Exits 0 when all
 * requests have been answered, 1 on timeout or server death.
 */

const fs = require('fs');
const readline = require('readline');
const { spawn } = require('child_process');

const TIMEOUT_MS = 30000;

function main() {
    const server = process.argv[2];
    const script = process.argv[3];
    if (!server || !script) {
        console.error('usage: mcp-client.js <server.js> <requests.jsonl>');
        process.exit(2);
    }
    const requests = fs.readFileSync(script, 'utf8')
        .split('\n')
        .filter((l) => l.trim())
        .map((l) => JSON.parse(l));

    const child = spawn(process.execPath, [server], {
        stdio: ['pipe', 'pipe', 'inherit'],
    });
    const rl = readline.createInterface({ input: child.stdout });

    const awaited = requests.filter((r) => r.id !== undefined).length;
    let answered = 0;
    let cursor = 0;

    const timer = setTimeout(() => {
        console.error('mcp-client: timeout');
        child.kill('SIGKILL');
        process.exit(1);
    }, TIMEOUT_MS);

    function pump() {
        // Send until we hit a request that expects a response.
        while (cursor < requests.length) {
            const req = requests[cursor];
            cursor++;
            child.stdin.write(JSON.stringify(req) + '\n');
            if (req.id !== undefined) return;
        }
        // All sent and all answered: done.
        if (answered >= awaited) {
            clearTimeout(timer);
            child.stdin.end();
            child.kill('SIGTERM');
            process.exit(0);
        }
    }

    rl.on('line', (line) => {
        if (!line.trim()) return;
        console.log(line);
        answered++;
        pump();
    });

    child.on('exit', (code) => {
        if (answered < awaited) {
            console.error(`server exited early (code ${code})`);
            process.exit(1);
        }
    });

    pump();
}

main();
