# Entry Format

## Entries

Each changelog entry MUST follow the repo's exact entry format (the PR-and-author link format defined by the repo's changelog policy in `.agents/agent-workflow.yml`). Match the existing entries in the changelog and follow these portable structural rules:

- Start with a dash followed by a space
- Use **bold** for the main description
- End the bold description with a period before the link
- Always link to the PR using the repo's PR-link format — **NO hash symbol** before the PR number
- Always link to the author
- End with a period after the author link
- Additional details can be added after the main entry, using proper indentation for multi-line entries

## Breaking changes

For breaking changes, lead the bold description, note the migration guide, append the repo's PR-and-author link, then the guide:

```markdown
- **Feature Name**: Description of the breaking change. See migration guide below. <repo PR-and-author link, per the changelog format above>

**Migration Guide:**

1. Step one
2. Step two
```

## Categories

Entries should be organized under these section headings **in the following order** (most critical first):

**Preferred section order:**

1. `#### Breaking Changes` - Breaking changes with migration guides (FIRST - most critical for upgrading users)
2. `#### Added` - New features
3. `#### Changed` - Changes to existing functionality
4. `#### Improved` - Improvements to existing features
5. `#### Fixed` - Bug fixes
6. `#### Deprecated` - Deprecation notices
7. `#### Removed` - Removed features
8. `#### Security` - Security-related changes

**Rationale:** Breaking changes come first because they are the most critical information for anyone upgrading. Users need to know immediately if their code will break before seeing what new features are available.

**Additional custom headings** (use sparingly when standard headings don't fit):

- `#### Documentation` - Documentation improvements
- `#### Developer (Contributors Only)` - Internal tooling changes
- `#### API Improvements` - API changes and improvements
- `#### Generator Improvements` - Generator-specific changes
- `#### Performance` - Performance improvements

**Prefer standard headings.** Only use custom headings when the change needs more specific categorization.

**Tagged entries**: When the repo's changelog policy defines an inline scope tag (such as a `**[Pro]**` prefix), apply it within the standard category sections (e.g., `- **[Pro]** **Feature name**: Description...`). Do NOT create separate per-tag subsections.

**Only include section headings that have entries.**

Use the existing changelog for concrete entry examples. Keep descriptions concise, use past tense, and preserve the repo's PR/author-link and inline-scope-tag conventions. End the file with a newline.
