# CHANGELOG format

Each release gets one short section. Readers want three answers: is it safe to upgrade, what do I have to change, and what got fixed. The PR and docs/guide.md carry the details.

```markdown
## X.Y.Z (YYYY-MM-DD)
<!-- title: one lowercase line, used as the GitHub release title -->

**Upgrade:** "Drop-in." Or list what can break and how to fix it, one line each:
- Boot: what now raises at class load. Fix: ...
- Requests: what is now refused or answered differently. Fix: ...
- Tooling: audit, export or generator output that changed.

### Security
- **What was wrong and what happens now, in one sentence.** One example if it helps. (#PR)

### Breaking
### Added
### Changed
### Fixed
```

Rules:
- Keep the section order shown above. Drop any heading that has no entries.
- Write each bullet as one bold sentence saying what changed, then at most two plain sentences. Give at most one example. Don't list edge cases.
- Write "was X, is now Y" for the behaviour. Describe what the user sees, not how the code does it.
- End each bullet with its PR number.
- In a PR, add bullets under `## Unreleased`. The Release commit renames that heading to `## X.Y.Z (date)`, adds the title marker, and writes the **Upgrade** line.
- Versions: use a patch release for fixes and security fixes that need no change from users. Use a minor release when any boot, request, audit gate, or spec that passes today can fail.
