# Security Policy

## Reporting a Vulnerability

Report suspected vulnerabilities through
[GitHub private vulnerability reporting](https://github.com/shakacode/agent-workflows/security/advisories/new).
Private reporting is a repository setting, so that form accepts reports only
while a maintainer keeps the setting enabled.

If the form does not open for you, file a public issue that asks a maintainer to
open a private channel and contains no vulnerability details, then send the
report only through the private channel a maintainer opens in reply.

Do not disclose vulnerability details in a public issue, pull request, or
discussion.

Include the affected workflow, skill, helper, or release; reproduction steps;
the expected impact; and any suggested mitigation. A maintainer will
acknowledge the report and coordinate disclosure and remediation through the
private channel.

## Scope

Agent Workflows distributes executable helpers and agent instructions for use
in consumer repositories. Identify the affected commit or release in the
private report so maintainers can determine the impacted versions.

See the [Agent Security Posture](docs/security-posture.md) for the pack's threat
model, trust boundaries, and handling of untrusted GitHub content.
