#!/usr/bin/env node
/**
 * scripts/jira-transition.js
 *
 * Transitions a Jira issue to a target status using the Jira REST API v3.
 *
 * Usage (called by GitHub Actions):
 *   node scripts/jira-transition.js --key ABC-123 --status "In QA" --env dev
 *
 * Required environment variables (set as GitHub Secrets / Vars):
 *   JIRA_BASE_URL    – e.g. https://yourorg.atlassian.net
 *   JIRA_EMAIL       – Atlassian account email
 *   JIRA_API_TOKEN   – Atlassian API token (not password)
 *
 * Transition ID env vars (GitHub Vars, per environment):
 *   JIRA_TRANSITION_DEV      – transition ID to move to "In QA"
 *   JIRA_TRANSITION_STAGING  – transition ID to move to "UAT"
 *   JIRA_TRANSITION_PROD     – transition ID to move to "Done"
 *
 * How to find transition IDs:
 *   curl -u email:token \
 *     "https://yourorg.atlassian.net/rest/api/3/issue/ABC-123/transitions" \
 *     | jq '.transitions[] | {id, name}'
 */

"use strict";

const https = require("https");
const url   = require("url");

// ── Parse CLI args ──────────────────────────────────────────────────────────
const args = process.argv.slice(2);
const get  = (flag) => {
  const i = args.indexOf(flag);
  return i !== -1 ? args[i + 1] : null;
};

const issueKey    = get("--key");
const targetStatus = get("--status");
const envName     = get("--env") || "dev";

if (!issueKey || !targetStatus) {
  console.error("Usage: node jira-transition.js --key PROJ-123 --status 'In QA' --env dev");
  process.exit(1);
}

// ── Config from env ──────────────────────────────────────────────────────────
const JIRA_BASE_URL  = process.env.JIRA_BASE_URL;
const JIRA_EMAIL     = process.env.JIRA_EMAIL;
const JIRA_API_TOKEN = process.env.JIRA_API_TOKEN;

if (!JIRA_BASE_URL || !JIRA_EMAIL || !JIRA_API_TOKEN) {
  console.error("Missing JIRA_BASE_URL, JIRA_EMAIL, or JIRA_API_TOKEN env vars.");
  process.exit(1);
}

// Transition ID lookup (GitHub Vars must be set per environment)
const TRANSITION_ID_MAP = {
  dev:     process.env.JIRA_TRANSITION_DEV,
  staging: process.env.JIRA_TRANSITION_STAGING,
  prod:    process.env.JIRA_TRANSITION_PROD,
};

const transitionId = TRANSITION_ID_MAP[envName];

// ── Helpers ──────────────────────────────────────────────────────────────────
const AUTH_HEADER = "Basic " + Buffer.from(`${JIRA_EMAIL}:${JIRA_API_TOKEN}`).toString("base64");

function jiraRequest(method, path, body) {
  return new Promise((resolve, reject) => {
    const parsed  = new url.URL(JIRA_BASE_URL + path);
    const options = {
      hostname: parsed.hostname,
      port:     parsed.port || 443,
      path:     parsed.pathname + parsed.search,
      method,
      headers: {
        Authorization:  AUTH_HEADER,
        "Content-Type": "application/json",
        Accept:         "application/json",
      },
    };

    const req = https.request(options, (res) => {
      let data = "";
      res.on("data", (chunk) => (data += chunk));
      res.on("end", () => {
        if (res.statusCode >= 200 && res.statusCode < 300) {
          resolve({ status: res.statusCode, body: data ? JSON.parse(data) : {} });
        } else {
          reject(new Error(`Jira API ${res.statusCode}: ${data}`));
        }
      });
    });

    req.on("error", reject);
    if (body) req.write(JSON.stringify(body));
    req.end();
  });
}

// ── Main logic ───────────────────────────────────────────────────────────────
async function main() {
  console.log(`\n🔍 Jira: transitioning ${issueKey} → "${targetStatus}" (env: ${envName})`);

  // Step 1: Fetch available transitions
  console.log("  Fetching available transitions…");
  const { body: { transitions } } = await jiraRequest(
    "GET",
    `/rest/api/3/issue/${issueKey}/transitions`
  );

  if (!transitions || transitions.length === 0) {
    console.error(`  ❌ No transitions found for issue ${issueKey}`);
    process.exit(1);
  }

  // Step 2: Resolve transition ID
  let resolvedId = transitionId;

  if (!resolvedId) {
    // Fall back to matching by name if no ID configured
    console.log("  No transition ID configured — matching by status name…");
    const match = transitions.find(
      (t) => t.name.toLowerCase() === targetStatus.toLowerCase() ||
             t.to?.name?.toLowerCase() === targetStatus.toLowerCase()
    );
    if (!match) {
      console.error(
        `  ❌ Could not find transition to "${targetStatus}". Available:\n` +
        transitions.map((t) => `     id=${t.id}  name="${t.name}"  to="${t.to?.name}"`).join("\n")
      );
      process.exit(1);
    }
    resolvedId = match.id;
    console.log(`  Matched transition id=${resolvedId} ("${match.name}")`);
  } else {
    console.log(`  Using configured transition id=${resolvedId}`);
  }

  // Step 3: Execute transition
  await jiraRequest("POST", `/rest/api/3/issue/${issueKey}/transitions`, {
    transition: { id: resolvedId },
  });

  console.log(`  ✅ ${issueKey} successfully transitioned to "${targetStatus}"\n`);

  // Step 4: Add a comment for traceability
  const commentBody = {
    body: {
      type: "doc",
      version: 1,
      content: [
        {
          type: "paragraph",
          content: [
            {
              type: "text",
              text: `🚀 Deployed to *${envName}* by GitHub Actions. Status: ${targetStatus}.`,
              marks: [{ type: "em" }],
            },
          ],
        },
      ],
    },
  };

  try {
    await jiraRequest("POST", `/rest/api/3/issue/${issueKey}/comment`, commentBody);
    console.log(`  💬 Comment added to ${issueKey}`);
  } catch (e) {
    console.warn(`  ⚠️  Could not add comment (non-fatal): ${e.message}`);
  }
}

main().catch((err) => {
  console.error("  ❌ Jira transition failed:", err.message);
  process.exit(1);
});
