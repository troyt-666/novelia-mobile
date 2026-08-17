---
status: accepted
---

# Whole-novel downloads track future chapters

Treat a Novel Download as persistent desired state rather than a snapshot of the chapters present when the reader taps download. While that intent remains enabled, background reconciliation automatically queues every future published chapter with its Japanese Original and the novel's selected Translation Source. This supports uninterrupted offline following at the cost of potentially unbounded storage and background work, which must remain visible and controllable through progress, pause, failure, storage, and removal UI.
