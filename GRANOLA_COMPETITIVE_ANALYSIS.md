# Scribeflow vs. Granola

Research snapshot: July 13, 2026

This document turns current Granola product research into implementation choices
for Scribeflow. The goal is not to clone Granola. The goal is to understand its
best product decisions, avoid its mobile constraints, and build a clearer reason
to choose Scribeflow.

## Executive Position

Granola is a polished AI notepad that combines a user's rough notes with a
transcript, then makes that meeting archive useful through chat, templates,
recipes, folders, people, companies, and integrations.

Scribeflow should own a narrower and more defensible position:

> The private meeting memory that proves what happened and closes the loop.

That means Scribeflow should be best when a user needs to prepare for a
conversation, capture it naturally, distinguish people, verify the recap, and
make sure commitments do not disappear afterward. The complete workflow should
work on iPhone, not depend on a desktop companion, and keep local-first data
boundaries visible.

## What Granola Does Well

- Human-guided enhancement: user notes remain the anchor and the transcript
  fills in context. Granola also exposes a zoom-in path to inspect where enhanced
  notes came from.
- Low-friction capture: no meeting bot joins desktop calls, and the iPhone app is
  designed for in-person meetings and outbound phone calls.
- Flexible outputs: built-in and custom templates adapt notes to meeting types.
- Meeting memory: chat works across one meeting, folders, people, companies, and
  broader meeting history.
- Repeatable workflows: recipes save prompts for common analysis and follow-up.
- Team distribution: shared folders, links, Slack, Notion, CRM, Zapier, MCP, and
  API options move notes into other work systems.
- Preparation: pre-meeting briefs bring forward prior notes, open threads, and
  optionally connected email or web context.

## Openings For Scribeflow

Granola's iPhone product currently depends on desktop for custom-template
creation, folder management, integration sharing, workspace changes, and
calendar configuration. iOS also prevents it from capturing the audio of a
different virtual-meeting app on the same phone.

Granola stores notes and transcripts in AWS in the United States. It says audio
is temporarily cached for transcription and then deleted. Scribeflow can offer a
meaningfully different boundary: local by default, explicit export or private
backup, and a configured transcription backend only when the user chooses that
deployment.

Granola's People and Companies directory is automatic, but its documentation
notes that people cannot be added manually and names or companies can sometimes
be wrong. Scribeflow can differentiate with editable speaker identities,
transparent identity matching, and source-linked relationship context.

Granola's Basic plan limits accessible history to a rolling 30-day window.
Scribeflow's owned local library can keep searchable history without making old
notes inaccessible behind a history window.

## Product Matrix

| Capability | Granola | Scribeflow direction |
|---|---|---|
| Bot-free capture | Strong on desktop; in-person and outbound calls on iPhone | Native iPhone capture with explicit consent and retention controls |
| Human-guided notes | Strong | Preserve verbatim user anchors and visually separate AI additions |
| Source inspection | Transcript zoom-in | Proof status, source note, transcript line, speaker, and editable evidence |
| Personal-note safety | Meeting-centered | Purpose classifier prevents fake tasks, risks, and decisions in personal notes |
| Pre-meeting prep | Prior notes plus optional connected sources | Local relationship matching plus unresolved commitments and direct source-note links |
| Follow-through | Chat and integrations | Native open loops, due dates, reminders, status, owner, priority, and rationale |
| People memory | Automatic People and Companies | Editable speaker labels plus attendee and transcript identity reconciliation |
| Templates | Custom templates, created on desktop | Full meeting lenses on iPhone; custom playbooks remain a next step |
| Recipes | Saved static prompts | Built-in recipes exist; editable and variable-aware recipes remain a next step |
| Collaboration | Mature shared folders and links | Not yet equivalent; optional encrypted sharing needs a real backend contract |
| Integrations | Broad | Webhooks and export foundation exist; first-class connectors remain a launch track |
| Data boundary | Cloud account with local cache | Local-first library with explicit backup and backend boundaries |

## Implemented From This Research

### Source-backed before-you-join brief

`MeetingPrep.swift` now builds event-specific prep from saved Scribeflow history.
It scores only plausible related notes using:

- attendee identity overlap;
- corrected transcript speaker identity;
- meaningful title and agenda overlap;
- calendar linkage;
- recency as a secondary signal.

Personal captures and live/incomplete meetings are excluded. Weak similarity
cannot pull unrelated notes into a brief. Carry-forward items display their
source meeting, and a user can open that note directly.

### Accountability-first context

The prep brief prioritizes open or at-risk commitments, then saved decisions,
open questions, and prior risks. This makes preparation actionable instead of
producing a generic summary of old conversations.

### Complete iPhone flow

Prep now opens from Today and Calendar before note creation. From the same sheet,
the user can inspect source notes, create or reopen the calendar note, or start
recording. A bottom safe-area inset keeps actions from covering content.

### Duplicate prevention

Calendar note lookup uses the event identifier first and a title/time fingerprint
as a fallback. Repeated Prep taps reopen the existing note instead of creating
duplicate meetings.

### Better relationship identity

People intelligence now reconciles calendar attendees with corrected transcript
speaker names. Generic labels such as `Speaker 1`, `Unknown`, and `Participant`
are rejected so they do not become false people records.

### Visible demo path

The sample workspace includes a prior Helio launch-readiness meeting and a linked
upcoming Helio review. Today can surface the saved upcoming event even without
Calendar permission, making the complete prep flow demonstrable offline.

## Next Product Work

### Custom playbooks on iPhone

Let users define the outcome, required sections, extraction strictness, and
share format for a meeting type. Keep playbooks structured rather than storing
an unrestricted prompt as the product contract.

### Editable, variable-aware recipes

Add saved recipes for one meeting or a selected scope. Support controlled
variables such as person, company, date range, meeting type, and output format.
Granola recipes are currently static prompts, so deterministic variables can be
a useful differentiation.

### Relationship workspace

Add merge, rename, and hide controls for people; derive companies only from
verified email domains or user confirmation; show a chronological relationship
timeline with open promises on both sides.

### Quality evaluation harness

Create a private fixture set for personal notes, calls, noisy transcripts,
multiple speakers, ambiguous owners, relative dates, and unsupported claims.
Track precision separately for decisions, actions, owners, due dates, speakers,
and source links. Accuracy should be measured, not described as 100 percent.

### Optional collaboration backend

Design encrypted sharing, revocation, workspace roles, audit events, and conflict
resolution before adding team collaboration UI. This is the largest remaining
product gap relative to Granola and should not be faked with local-only screens.

### Integration contracts

Promote the existing export and webhook foundation into audited connectors for
Slack, Notion, and one CRM. Every connector should have retry state, idempotency,
clear scope, and a visible last-sync result.

## Research Sources

- [Granola for iPhone](https://docs.granola.ai/help-center/ios/getting-started)
- [Writing notes on iOS](https://docs.granola.ai/help-center/ios/taking-notes)
- [AI-enhanced notes and source inspection](https://docs.granola.ai/help-center/taking-notes/ai-enhanced-notes)
- [Custom templates](https://docs.granola.ai/help-center/taking-notes/customise-notes-with-templates)
- [Granola Chat](https://docs.granola.ai/help-center/getting-more-from-your-notes/chatting-with-your-meetings)
- [Recipes](https://docs.granola.ai/help-center/getting-more-from-your-notes/recipes)
- [Pre-meeting briefs](https://docs.granola.ai/help-center/taking-notes/pre-meeting-briefs)
- [People and Companies](https://docs.granola.ai/help-center/people-and-companies)
- [Spaces and folders](https://docs.granola.ai/help-center/sharing/folders/spaces-and-folders)
- [Integrations](https://docs.granola.ai/help-center/sharing/integrations/integrations-with-granola)
- [Security, privacy, and data FAQ](https://docs.granola.ai/help-center/consent-security-privacy/security-privacy-data-faqs)
- [Plan comparison](https://www.granola.ai/blog/granola-free-vs-paid-features-each-plan)
