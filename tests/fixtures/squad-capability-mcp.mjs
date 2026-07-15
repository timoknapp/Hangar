import readline from 'node:readline';
import { readFileSync, readdirSync, writeFileSync } from 'node:fs';

const forbiddenNames = [
  'COPILOT_GITHUB_TOKEN',
  'GITHUB_TOKEN',
  'GH_TOKEN',
  'COPILOT_PAT',
];

function assertCredentialIsolation() {
  const findings = [];
  for (const name of forbiddenNames) {
    if (Object.hasOwn(process.env, name)) {
      findings.push(`self:${name}`);
    }
  }

  for (const pid of readdirSync('/proc').filter((entry) => /^\d+$/.test(entry))) {
    try {
      const environ = readFileSync(`/proc/${pid}/environ`);
      for (const name of forbiddenNames) {
        if (environ.includes(Buffer.from(`${name}=`))) {
          findings.push(`pid-${pid}:${name}`);
        }
      }
    } catch (error) {
      if (error?.code === 'EACCES' || error?.code === 'EPERM' || error?.code === 'ENOENT') {
        continue;
      }
      throw error;
    }
  }

  if (findings.length > 0) {
    writeFileSync(
      new URL('.squad-capability-mcp-diagnostic', import.meta.url),
      `${findings.join('\n')}\n`,
    );
    throw new Error('credential isolation failed; see diagnostic marker names');
  }
}

const lines = readline.createInterface({ input: process.stdin });

function respond(id, result) {
  process.stdout.write(`${JSON.stringify({ jsonrpc: '2.0', id, result })}\n`);
}

lines.on('line', (line) => {
  if (!line.trim()) return;

  const request = JSON.parse(line);
  if (request.method === 'initialize') {
    respond(request.id, {
      protocolVersion: request.params.protocolVersion,
      capabilities: { tools: {} },
      serverInfo: { name: 'squad-capability-probe', version: '1.0.0' },
    });
    return;
  }

  if (request.method === 'tools/list') {
    respond(request.id, {
      tools: [
        {
          name: 'capability_marker',
          description: 'Return the full Squad repository MCP capability marker.',
          inputSchema: { type: 'object', properties: {}, additionalProperties: false },
        },
      ],
    });
    return;
  }

  if (request.method === 'tools/call') {
    assertCredentialIsolation();
    writeFileSync(new URL('.squad-capability-mcp-used', import.meta.url), 'SQUAD_MCP_OK\n');
    respond(request.id, {
      content: [{ type: 'text', text: 'SQUAD_MCP_OK' }],
      isError: false,
    });
    return;
  }

  if (request.id !== undefined) {
    respond(request.id, {});
  }
});
