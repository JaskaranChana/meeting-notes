# Scribeflow Investor Readiness

Use this file before investor demos, TestFlight reviews, and product walkthroughs.
The goal is a repeatable story: private capture, trusted intelligence, follow-up,
and user-controlled backup.

## Demo Story

- Open Settings and enable Investor demo mode.
- Reset the demo workspace before a live walkthrough.
- Start on Today and launch the four-part presentation from the demo-mode banner.
- Open Calendar to show meeting context and open loops.
- Open a meeting and tap source proof on a decision, action, risk, or summary.
- Mark or review an action item from Tasks.
- Ask a question from the library and point to source-backed answers.
- Open Impact to show local capture and follow-through outcomes.
- Open Storage & backup and show automatic recovery, export, and restore preview.

## Product Proof

- Personal notes stay personal and do not become fake tasks, risks, or decisions.
- Meeting/call captures can produce decisions, action items, risks, source proof,
  and follow-up prompts.
- Backup is local-first: users can export a full copy or notes-only copy.
- Restore is previewed before replacing local data.
- Automatic snapshots are protected on-device and keep a bounded recovery history.
- Notification taps route directly to the meeting that owns the action.
- Calendar reads and backup work run away from the main UI path.
- iCloud backup is optional and private; the code foundation is present, but
  device builds must not claim it until the CloudKit entitlement/profile is enabled.
- The app remains usable without iCloud.

## Release Checks

- Build the app target before every demo.
- Do not demo with an unprepared local workspace.
- Keep the bottom dock clear of scroll content on all root tabs.
- Verify note typing and meeting scrolling feel smooth on the demo device.
- Verify CloudKit container `iCloud.ai.scribeflow.app` exists and the
  provisioning profile includes iCloud before wiring `Scribeflow.entitlements`
  into the app target.
- Deploy CloudKit schema before App Store release.
- Keep privacy copy aligned with actual storage behavior.

## Completed Investor Polish

- On-device usage impact for captures, retained minutes, closed loops,
  follow-through, and source-backed items.
- Dedicated presentation mode driven by the current local workspace.
- Source inspector for individual decisions, actions, risks, questions, and summaries.
- Calendar and backup work moved off the main UI path to reduce stalls.

## External Launch Gates

- Enable the CloudKit container in the Apple Developer account, update the
  provisioning profile, wire the entitlement, and deploy the production schema.
- Configure a production transcription endpoint and credentials before claiming
  backend transcription or speaker diarization.
- Build CI is present; add device-level launch smoke automation only when the
  project owner requests it and the simulator environment is dependable.
