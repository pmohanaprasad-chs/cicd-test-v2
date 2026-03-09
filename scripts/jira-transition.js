#!/usr/bin/env node
// =============================================================================
// jira-transition.js
//
// Usage:
//   Create ticket:
//     node jira-transition.js --action create --project CSD --summary "..." --description "..."
//     Prints created issue key to stdout (e.g. CSD-123)
//
//   Transition ticket:
//     node jira-transition.js --action transition --key CSD-123 --status "In Progress"
//
//   Comment on ticket:
//     node jira-transition.js --action comment --key CSD-123 --comment "Deployed to staging ✅"
//
// Env vars required:
//   JIRA_BASE_URL   e.g. https://yourorg.atlassian.net
//   JIRA_EMAIL      your Atlassian account email
//   JIRA_API_TOKEN  Atlassian API token
// =============================================================================

const https = require('https');
const url = require('url');

// ── helpers ──────────────────────────────────────────────────────────────────

function getArg(name) {
  const idx = process.argv.indexOf(`--${name}`);
  return idx !== -1 ? process.argv[idx + 1] : null;
}

function jiraRequest(method, path, body) {
  return new Promise((resolve, reject) => {
    const base = process.env.JIRA_BASE_URL.replace(/\/$/, '');
    const email = process.env.JIRA_EMAIL;
    const token = process.env.JIRA_API_TOKEN;
    const auth = Buffer.from(`${email}:${token}`).toString('base64');
    const parsed = url.parse(`${base}${path}`);
    const payload = body ? JSON.stringify(body) : null;

    const options = {
      hostname: parsed.hostname,
      path: parsed.path,
      method,
      headers: {
        Authorization: `Basic ${auth}`,
        'Content-Type': 'application/json',
        Accept: 'application/json',
        ...(payload ? { 'Content-Length': Buffer.byteLength(payload) } : {}),
      },
    };

    const req = https.request(options, (res) => {
      let data = '';
      res.on('data', (chunk) => {
        data += chunk;
      });
      res.on('end', () => {
        if (res.statusCode >= 200 && res.statusCode < 300) {
          resolve(data ? JSON.parse(data) : {});
        } else {
          reject(
            new Error(
              `Jira API ${method} ${path} → ${res.statusCode}: ${data}`,
            ),
          );
        }
      });
    });

    req.on('error', reject);
    if (payload) req.write(payload);
    req.end();
  });
}

// ── actions ──────────────────────────────────────────────────────────────────

async function createIssue({ project, summary, description }) {
  // All logs go to stderr — stdout is reserved for the clean issue key only
  process.stderr.write(
    `Creating Jira task in project ${project}: "${summary}"\n`,
  );
  const body = {
    fields: {
      project: { key: project },
      summary,
      description: {
        type: 'doc',
        version: 1,
        content: [
          {
            type: 'paragraph',
            content: [{ type: 'text', text: description || summary }],
          },
        ],
      },
      issuetype: { name: 'Task' },
    },
  };

  const result = await jiraRequest('POST', '/rest/api/3/issue', body);
  process.stderr.write(`✅ Created issue: ${result.key}\n`);
  // Only the key goes to stdout so $() capture is clean
  process.stdout.write(result.key);
  return result.key;
}

async function transitionIssue({ key, status }) {
  console.log(`Transitioning ${key} → "${status}"`);

  // Fetch available transitions
  const { transitions } = await jiraRequest(
    'GET',
    `/rest/api/3/issue/${key}/transitions`,
  );
  const match = transitions.find(
    (t) => t.name.toLowerCase() === status.toLowerCase(),
  );

  if (!match) {
    const available = transitions.map((t) => t.name).join(', ');
    console.warn(
      `⚠️  Transition "${status}" not found for ${key}. Available: ${available}`,
    );
    console.warn('Skipping transition (non-fatal).');
    return;
  }

  await jiraRequest('POST', `/rest/api/3/issue/${key}/transitions`, {
    transition: { id: match.id },
  });
  console.log(`✅ ${key} transitioned to "${status}"`);
}

async function addComment({ key, comment }) {
  console.log(`Adding comment to ${key}`);
  const body = {
    body: {
      type: 'doc',
      version: 1,
      content: [
        {
          type: 'paragraph',
          content: [{ type: 'text', text: comment }],
        },
      ],
    },
  };
  await jiraRequest('POST', `/rest/api/3/issue/${key}/comment`, body);
  console.log(`✅ Comment added to ${key}`);
}

// ── main ─────────────────────────────────────────────────────────────────────

async function main() {
  const action = getArg('action');

  if (!action) {
    // Legacy compatibility: old usage was --key X --status Y
    const key = getArg('key');
    const status = getArg('status');
    if (key && status) {
      await transitionIssue({ key, status });
      return;
    }
    console.error('--action is required (create | transition | comment)');
    process.exit(1);
  }

  switch (action) {
    case 'create': {
      const project = getArg('project');
      const summary = getArg('summary');
      const description = getArg('description') || '';
      if (!project || !summary) {
        console.error('--project and --summary are required for create');
        process.exit(1);
      }
      await createIssue({ project, summary, description });
      break;
    }

    case 'transition': {
      const key = getArg('key');
      const status = getArg('status');
      if (!key || !status) {
        console.error('--key and --status are required for transition');
        process.exit(1);
      }
      await transitionIssue({ key, status });
      break;
    }

    case 'comment': {
      const key = getArg('key');
      const comment = getArg('comment');
      if (!key || !comment) {
        console.error('--key and --comment are required for comment');
        process.exit(1);
      }
      await addComment({ key, comment });
      break;
    }

    default:
      console.error(
        `Unknown action: ${action}. Use create | transition | comment`,
      );
      process.exit(1);
  }
}

main().catch((err) => {
  console.error('❌ Jira error:', err.message);
  process.exit(1);
});
