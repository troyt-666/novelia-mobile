# JFZ Reader project guide

The Flutter application is in `app/`. Read `app/AGENTS.md` before application
work; `CONTEXT.md` defines the domain terminology.

## UI/UX work

- Read `PRODUCT.md` and `DESIGN.md` for UI/UX tasks. Use
  `docs/ui-ux-workflow.md` when starting a review or choosing a design workflow.
- Use the project-local Impeccable skill for scoped design work. User intent,
  established reading contracts, and target-platform behavior take precedence
  over generic aesthetic heuristics. Preserve the current identity unless the
  task requests a redesign.
- Verify Flutter interfaces with native runtime evidence and fixture data.
  Distinguish source-based findings from observed behavior; browser previews
  do not establish mobile or HarmonyOS correctness.
