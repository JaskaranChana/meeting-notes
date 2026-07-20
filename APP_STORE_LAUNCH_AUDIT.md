# Scribeflow Professional iOS Product Audit

Audit date: 17 July 2026
Target reviewed: Scribeflow 1.0 (build 2), iPhone, iOS 17+  
Original audit decision: **NO-GO before repository remediation**  
Current repository decision: **GO for signed device certification; NO-GO for public submission until the external release gates below are complete**  
Original pre-remediation product score: **7.1/10**  
Original pre-remediation App Store readiness: **58/100**

## Remediation Applied In The Working Tree

The repository now addresses the deterministic product issues found by this audit:

- Calendar weekday cells use stable positional identity.
- Today, Library, Tasks, Calendar, Ask, Capture, Folder Detail, and Meeting Detail use adaptive layouts for accessibility text sizes, with primary content no longer artificially truncated.
- The native launch background matches the app in light and dark appearance; returning users skip the decorative splash and first run uses a short Reduce Motion-aware transition.
- Quick notes and recordings default independently to a neutral General template.
- Capture details are progressive, and the live-caption mark action is a real button.
- Root screens use one visible title, the last selected root is restored, and the icon-only dock retains stable geometry and accessibility names.
- Folder Detail is searchable and uses a compact note list with an optional source-linked Ask tool.
- Generated decisions, risks, actions, details, and sections are filtered against saved evidence; unsupported owner and due-date metadata is removed.
- Personal captures continue to suppress work-only decisions, tasks, risks, owners, and scores unless the user explicitly changes the purpose.
- Cloud backup controls remain hidden unless the installed build declares that capability, and the privacy policy now covers Reminders and notifications.
- Reset plus seed launch arguments now produce a clean seeded workspace.
- Shipping orientation is restricted to the portrait layout currently supported by the product.

The remaining release gates require external evidence rather than more interface code: signed capability configuration, a qualified legal review, App Store Connect assets and metadata, and physical-device capture, interruption, notification, accessibility, performance, archive, and restore certification.

### Post-Audit Stabilization Update

After the audit snapshot, the working tree also implemented the remaining
repository-controlled reliability work: enforced transcript/audio retention,
background app relocking, single-source AI claim validation, immediate durable
Save handoff, off-main imported-audio preflight and automatic transcription,
resource-aware model fallback, bounded full backups, protected digest-based
persistence, complete pending-data deletion, route-derived dock visibility,
mode-correct week calendar navigation, stronger contrast and Dynamic Type in
Settings, explicit notification permission timing, opaque app-icon files,
targeted strict-concurrency checking, and Debug-test plus Release-build CI.

The audit's device, signing, legal, App Store Connect, and measured-performance
gates remain intentionally open. No repository change can honestly certify
those external conditions.

### 17 July Static Re-Audit

This pass concentrated on frequently repeated interactions rather than adding
more product surface:

- Persistence now snapshots the meeting library after its debounce window
  instead of retaining a full array copy on every edit.
- ID lookups validate and repair their index while note editing and delayed
  regeneration use the constant-time path.
- Retention deadline calculation is coalesced instead of rescanning the full
  library and replacing its timer on every meeting mutation.
- Standalone voice-note Save returns after the durable meeting is created;
  optional note rewriting continues in the background.
- The live capture stage and Today hero no longer use large blurred decorative
  layers in always-visible surfaces.
- Calendar-created notes receive a useful start and end time, retain calendar
  context, and open immediately.
- Today routes pinned and recent "View all" actions to Library, while open-loop
  actions continue to route to Tasks.
- Meeting Tasks no longer repeat extracted follow-ups when the same items are
  already represented by stored commitments.
- Storage totals and recording sizes are computed by an actor and cached in
  view state; opening or redrawing Data Controls no longer performs synchronous
  file-system reads from `body`.
- Backup export returns its encoded data and preview together, while restore
  decodes and validates the archive once, off the main actor, with a 128 MB
  package ceiling and the same 64 MB embedded-audio ceiling used by export.
- Restored audio is installed through a staged atomic swap with rollback.
  Before replacing the library, Scribeflow durably flushes the current state,
  cancels work owned by the old library, removes stale reminder identifiers,
  and then persists the restored state before rebuilding derived data.
- The restore UI remains dismiss-safe, reports preparation and installation
  progress, and debounces storage refreshes after library mutations.
- Root meeting mutations, transcript recovery, note polishing, and AI
  completions now use the store's validated constant-time ID index instead of
  repeatedly scanning the complete library.
- Derived-data migration only visits stale rows and uses the same indexed
  lookup, avoiding quadratic launch work as a library grows.
- Main and recovery JSON files use mapped reads where the platform can provide
  them, reducing unnecessary copy pressure for larger libraries.

The highest remaining performance risk is architectural: launch still decodes
a whole-library JSON document before the first usable store is available.
Restore preparation and file installation are now actor-isolated, bounded, and
transactional, but the eventual scalability project remains record-level
persistence with a staged migration and paged queries. That is a storage
architecture change, not a safe last-minute release tweak.

The largest source files also remain maintainability risks. Splitting them
should follow feature boundaries already documented in `Scribeflow/SOURCE_MAP.md`
and should be protected by the existing characterization tests.

The final compile-only Debug simulator build succeeded for arm64 and x86_64.
This re-audit did not run tests, screenshots, Instruments, or physical-device
sessions, following the requested verification scope. Its performance
conclusions remain static code assessments until the device certification
checklist is completed.

### 18 July Reliability Refinement

This pass removed additional work from common editing paths and tightened
library-replacement safety:

- After the current library has been validated once, persistence no longer
  rereads, rehashes, and decodes the complete JSON document before every
  changed save. Recovery snapshots use an atomic, APFS-friendly file copy, and
  a missing current file is still repaired on the next write.
- The root Tasks badge is derived by a debounced actor snapshot instead of
  scanning every meeting and commitment synchronously on each store revision,
  including revisions generated while typing.
- Spotlight indexing is now structured, cancellable, idle-debounced work.
  Deletes, sample replacement, restore, and full data deletion also remove
  stale index entries explicitly.
- Backup restore pauses and drains pending speech processing before swapping
  the recording directory. A failed install resumes the existing library,
  while a successful install discards work that belonged to the old library.
- Processing teardown remains paused until its active task and retry wake have
  both been cancelled, preventing an orphan retry from reappearing during
  restore or full deletion.
- The last root commitment-resolution path now uses the store's validated
  constant-time meeting lookup.

The compile-only Debug simulator build succeeded for arm64 and x86_64 after
these changes. Tests, screenshots, Instruments, and physical-device sessions
were not run, following the requested verification scope.

Whole-library JSON decoding at launch remains the principal scalability limit.
Replacing it with record-level persistence and paged queries still requires a
versioned migration, rollback plan, and device measurements; it should be
treated as a dedicated storage project rather than folded into routine polish.

### 19 July Interaction Refinement

This pass reduced repeated work in the screens and maintenance paths most
likely to be active during daily use:

- Root launch no longer sorts the complete library merely to preselect an
  otherwise unread meeting identifier.
- Tasks caches its flattened commitments and urgency summary by store
  revision. Typing a search now filters the stable task layer instead of
  rebuilding every workspace commitment and deadline count per character.
- Transcript search reuses its revision-scoped lines and word count rather
  than recounting the full transcript for every query update.
- Today no longer computes unused collection, duration, and trailing-meeting
  aggregates. Its visible priority plan uses a bounded top-three selection
  instead of sorting every commitment, and its open-loop model retains only
  the three rows the screen can present while preserving the full count.
- Prepared-calendar-note discovery moved into the Today snapshot actor, so
  publishing a refreshed snapshot no longer scans the library on the main
  actor.
- Calendar caches month grouping, event links, sorted agendas, and counts by
  data revision. Selecting another date now updates lightweight cell
  selection and that day's agenda without rebuilding the complete month.
- Today and Calendar own EventKit refreshes through structured, cancellable
  tasks, coalescing month changes, foreground transitions, and event-store
  notifications.
- Routine automatic-backup interval checks and pruning use file metadata.
  Existing full-library archives are decoded only when the user opens backup
  management, and archive reads use mapped data where available.

The compile-only Debug simulator build succeeded for arm64 and x86_64 after
these changes. Tests, screenshots, Instruments, and physical-device sessions
were not run, following the requested verification scope. Runtime improvement
claims still require the same oldest-device interaction trace described by the
release gate.

### 19 July Mutation Pipeline Refinement

This pass reduced redundant store publication and made background derivation
ownership explicit:

- Note regeneration is now owned per meeting. Editing one note no longer
  cancels pending summary, evidence, or intelligence work for another note,
  and destructive library operations cancel every owned task.
- No-op guards prevent unchanged titles, notes, modes, consent, retention,
  reminders, sharing state, processing stages, and live transcript callbacks
  from advancing the store revision or scheduling persistence.
- Task, reminder, speaker, transcript, recording, and processing mutations now
  publish complete meeting values atomically. Speaker rename no longer emits a
  library-wide observation update for every matching transcript line.
- Duplicate live recognition callbacks are ignored by semantic content, which
  avoids redraw and persistence work caused only by regenerated line IDs.
- Spotlight performs one launch reconciliation and then serially indexes only
  changed meetings. Failed removals remain queued, and root refreshes run
  after a five-second idle window at utility priority.
- Superseded-commitment lookup is linear and no longer sorts the full library
  after each regeneration.
- Bulk recording cleanup refreshes only affected meetings and runs the
  superseded-commitment pass once after the batch.
- Generated lists that can contain duplicate text use positional identity, so
  SwiftUI does not merge or unpredictably reuse repeated rows.

The compile-only Debug simulator build completed successfully after these
changes. Tests, screenshots, Instruments, and physical-device sessions were
not run, following the requested verification scope.

Whole-library JSON persistence remains the main scaling boundary. Record-level
storage, migration, rollback, and oldest-device measurements remain a separate
release project rather than an appropriate speculative change in this pass.

### 20 July State, Identity, And Speech Refinement

This pass tightened the app's highest-frequency state and background paths:

- Regenerated template summaries, summary sections, evidence rows, source
  references, live transcript lines, and open loops now retain semantic
  identity. Equivalent regeneration no longer replaces every SwiftUI row or
  creates a changed persistence payload solely from fresh UUIDs.
- Derived refresh compares the completed meeting value with its source and
  skips publication when nothing changed.
- Store mutations declare their actual effects. Pin, share, reminder, task
  status, score, and processing-label changes no longer clear semantic caches
  or rescan retention deadlines.
- Semantic cache eviction is scoped to the changed meeting. Prep and
  collection caches remain globally invalidated where their cross-meeting
  dependencies require it.
- Title, mode, consent, purpose, template, speaker, transcript, recording, note
  rewrite, and AI-result paths publish coherent meeting values instead of
  exposing partially updated intermediate states.
- Bulk audio cleanup derives affected meetings before one library
  publication, rather than publishing the batch and then publishing each
  regenerated meeting again.
- Cancelled persistence snapshots are discarded before encoding or entering
  the protected file-write path, reducing stale whole-library work during
  rapid edits.
- AI results verify that the title, objective, notes, transcript, purpose, and
  capture mode still match their input snapshot before publication. Slow model
  output cannot overwrite newer user edits.
- Root badge and Spotlight observation now lives in a dedicated maintenance
  view, so store revisions do not invalidate the complete root tab shell.
- Legacy live speech rotates its recognition request after debounced context
  changes, applying newly entered participant names and vocabulary immediately
  instead of waiting for the next long-session rotation.
- Meeting Detail state is private to the owning view, matching SwiftUI
  Observation ownership rules and reducing accidental API surface.

The compile-only Debug simulator build completed successfully after these
changes. `git diff --check` was clean before documentation. Tests, screenshots,
Instruments, simulator interaction, and physical-device sessions were not run,
following the requested verification scope.

Whole-library JSON storage remains the principal long-library scaling limit,
and speech accuracy still requires representative device recordings across
rooms, microphones, accents, interruptions, and speaker counts before release
claims can be certified.

## Original Audit Verdict

The section below records the audit snapshot that drove the stabilization
work. It is retained as historical evidence; issues listed here are not a
current open-work list. The remediation summary above and the external gates
are the current source of truth.

Scribeflow is no longer a prototype. It has a differentiated product core: a local-first capture workflow, source-backed summaries, purpose-aware intelligence, action follow-through, calendar context, recall, backup controls, and unusually honest confidence language. Those pieces create a credible product story and a stronger trust model than many meeting-note apps.

The current build is not yet ready for a public App Store launch. The blockers are not a lack of features. They are visible quality failures in the primary experience:

- The Calendar weekday header drops repeated weekdays because duplicate strings are used as SwiftUI identities.
- Accessibility text sizes break the Today layout and truncate core task meaning.
- The native launch screen flashes white before a dark branded splash.
- The app icon and in-app brand mark do not read strongly at small sizes.
- The icon-only custom dock is less discoverable than a native labeled tab bar.
- Quick Note defaults to a sales-oriented Discovery template, which contradicts the app's personal-note positioning.
- Several screens repeat the same title two or three times and spend too much of the first viewport on ornamental hierarchy.
- Seed/generated copy contains malformed or unpolished text that weakens trust in the intelligence layer.
- CloudKit and production transcription claims must be aligned with the capabilities actually shipped in the signed binary.
- Real-device microphone, speaker separation, background completion, notification, archive, and App Review flows remain unverified.

The right next move is a stabilization release, not another feature phase. Scribeflow can become App Store quality without changing its core concept, but the product needs restraint, accessibility, capability honesty, and device-level proof.

## Original Audit Scorecard

| Area | Score | Assessment |
|---|---:|---|
| Product concept | 8.4/10 | Clear need, strong end-to-end workflow, meaningful differentiation |
| First impression | 7.1/10 | Distinctive and polished at first glance, but occasionally overdesigned |
| Visual design | 7.2/10 | Cohesive editorial system and strong dark mode; hierarchy is too repetitive |
| Navigation | 6.4/10 | Stable five-domain model; icon-only custom dock reduces clarity |
| Core UX | 6.7/10 | Broad workflow coverage; capture and detail flows still carry excess ceremony |
| AI trust and explainability | 8.2/10 | Source proof, purpose, confidence, and inference labels are major strengths |
| Copy quality | 6.0/10 | Good product voice, but visible generated/seed errors and excess jargon remain |
| Accessibility | 4.8/10 | Good semantic work in code; critical Larger Text failures in rendered UI |
| Performance readiness | 6.6/10 | Several thoughtful optimizations; runtime performance remains unmeasured |
| Stability readiness | 6.4/10 | Release simulator build succeeds; key real-device flows are not certified |
| Privacy and user control | 8.2/10 | Local-first defaults, export, deletion, app lock, and transparent limitations |
| App Store completeness | 5.8/10 | Legal URLs work, but release capabilities, assets, metadata, and device QA remain |

## Audit Scope And Evidence

This audit used only evidence visible in the repository and rendered app.

Reviewed evidence:

- Repository-wide screen, route, permission, entitlement, accessibility, and performance-pattern inventory.
- Targeted review of every primary surface and its supporting state/persistence code.
- Release configuration simulator build with signing disabled: **BUILD SUCCEEDED**.
- iPhone 17 on iOS 26.3 in light and dark appearance.
- iPhone SE (3rd generation) on iOS 18.2 at standard and Accessibility Extra Large text.
- Release onboarding, native launch, SwiftUI splash, Today, Library, Tasks, Calendar, Ask, Quick Note, Live Capture, Meeting Detail, and Folder Detail.
- Public Privacy Policy and Terms URLs, both returning HTTP 200 on 15 July 2026.
- Current Apple Human Interface Guidelines and App Review Guidelines.
- Current official interaction documentation for Apple Notes, Reminders, Calendar, Journal, and Photos, plus Notion, Linear, Things, Craft, and Fantastical.

Not completed in this audit:

- No unit, UI, snapshot, or integration test suite was run.
- No Instruments Time Profiler, SwiftUI, Core Animation, memory, energy, or network trace was run.
- No VoiceOver traversal or Accessibility Inspector audit was run.
- No physical-device microphone, interruption, route-change, notification, or speaker-separation session was run.
- No signed archive, provisioning profile, CloudKit production schema, App Store Connect metadata, or review account was validated.
- Landscape was not rendered, even though the app currently declares landscape support.
- iPad was not assessed because the target is configured for iPhone only.

Performance and speech-quality conclusions are therefore code-backed risk assessments, not measured production guarantees.

## Product First Impression

### What the app communicates immediately

The product is understandable: capture a conversation or thought, get a structured record, follow up on commitments, and retrieve the source later. The strongest first-impression signals are privacy, memory, accountability, and evidence. This is more defensible than presenting Scribeflow as another generic AI summarizer.

### Emotional tone

The dark teal capture stage, editorial serif headings, restrained coral/gold accents, and source-proof language create a serious, thoughtful tone. Dark mode is especially coherent. The app feels designed by someone with a point of view.

At the same time, the interface sometimes tries too hard to signal premium quality through oversized headings, gradients, glass, nested panels, monospaced eyebrows, metric strips, and entrance motion. Premium productivity software feels calm because it removes decisions and decoration. Scribeflow is close, but it still occasionally displays its design system instead of the user's information.

### Trust

Trust is the product's strongest design advantage. The app exposes:

- Source meeting and source snippets.
- Confidence language.
- Inferred versus observed distinctions.
- Speaker-review states.
- Local/remote processing status.
- Processing and retry states.
- Recording limitations and consent guidance.
- Export, restore preview, deletion, and local activity controls.

This should remain central. Do not bury it behind generic AI language or replace it with decorative confidence scores.

## Complete UX Audit

### Onboarding

**Score: 7.5/10**

Strengths:

- The opening promise, "Talk it through. Keep it all.", is clear and memorable.
- The three-page sequence explains capture, review, recall, privacy, and call limitations.
- Skip and Continue are visible and predictable.
- The final page handles recording constraints before the first capture.

Issues:

- "4 capture modes" and "1 memory library" are implementation counts, not user outcomes.
- The main call-to-action is visually closer to a marketing page than a quiet system workflow.
- Cards inside a card-heavy onboarding flow make the screen feel longer than its content.
- Permission expectations are described, but the actual just-in-time permission sequence is not previewed.
- The first page promises decisions and follow-ups before explaining that outputs can require review.

Recommendation:

Use three short outcomes: Capture anything, Review with sources, Follow through. Replace feature counts with one concrete private-by-default statement. Keep the recording limitations page, but make "You control when recording starts" explicit.

### Information architecture

The five top-level domains are reasonable:

- Today: attention and next moves.
- Library: durable records.
- Tasks: open commitments.
- Calendar: temporal context.
- Ask: cross-note retrieval.

The problem is not the domain model; it is visual prioritization. Today, Tasks, Library, Calendar, and Ask all compete to be primary. The product needs one daily center (Today), one durable archive (Library), and fast contextual paths to the rest. Tasks and Calendar can remain tabs, but the app should reduce repeated entry points and duplicated summaries.

### Primary workflow

The intended flow is complete:

Capture/import/type -> save -> background refinement -> review -> verify sources -> act/share -> recall later.

The flow's main friction points are:

- Capture asks for title, objective, attendees, speaker count, and template before a user has started speaking.
- Quick Note inherits work-meeting template language.
- The record button sits deep inside a large stage rather than acting as the unmistakable first action.
- Meeting Detail exposes many capabilities at once and becomes a long destination rather than a concise record with progressive disclosure.
- The post-save background model is correct, but it still needs physical-device proof under termination, interruption, and denied notifications.

### Feedback and recovery

This is stronger than average. The code includes processing states, retry paths, permission recovery, backup recovery, source-review states, save toasts, notification status, and diagnostics. The product generally tells the user what is happening.

The remaining issue is prioritization. Some states are expressed through multiple badges, captions, dots, and metadata fragments. A user should see one primary state, one next action, and optional detail.

## Apple HIG Audit

### Tab navigation

Apple's current guidance recommends labels because they clearly describe each top-level destination. Scribeflow supplies accessibility labels but intentionally hides visual labels. That makes first-use recognition dependent on interpreting `rectangle.stack`, `checklist`, and `magnifyingglass` correctly.

Finding: **High**

- The custom dock is stable and reserves layout space, so it no longer covers root content.
- Touch targets are at least 44 points and selected traits are exposed.
- Re-tapping a selected tab scrolls to top, which is useful.
- The centered Today button changes the expected tab order and visual weight.
- The custom implementation will require continued maintenance across compact height, landscape, system material changes, and future tab-bar behavior.

Recommendation:

Adopt native `TabView` tabs with single-word labels and SF Symbols for the shipping build. If the custom dock remains a product requirement, show labels at least for the selected tab, test every compact-height configuration, and keep the same item order everywhere.

### Launching

Finding: **High**

`Info.plist` defines an empty `UILaunchScreen`, producing a blank white native screen. The app then transitions to a dark teal animated splash for 1.7 seconds. This creates exactly the discontinuity Apple's launch guidance warns against.

Recommendation:

- Make the native launch background match the first rendered frame in light and dark appearance.
- Remove the mandatory 1.7-second delay for returning users.
- If a branded splash is retained, use it only as part of first-run onboarding.
- Restore the previous root tab or detail route when practical instead of always starting at Today.

### Typography

Finding: **Critical**

The code has a scaling helper, but many screens still use explicit system sizes and one- or two-line limits. On the small iPhone at Accessibility Extra Large, the Today greeting breaks inside a word and task titles lose essential meaning.

Recommendation:

- Use semantic text styles for primary UI.
- Remove fixed sizes and line limits from user-authored or AI-authored primary content.
- Switch horizontal metric rows to vertical layouts at accessibility categories.
- Allow headings, task titles, metadata, and controls to grow without overlapping or truncating meaning.
- Certify all common tasks at AX1 through AX5 before claiming Larger Text support.

### Controls and gestures

Most important controls are real `Button`, `Menu`, `Picker`, or `NavigationLink` instances. A few content gestures remain, including tapping live captions to mark a moment. Gesture-only actions need an explicit visible control and equivalent accessibility action.

The interface generally uses familiar SF Symbols and appropriate semantic controls. The main exceptions are ambiguous icon-only controls, the "Auto" chat mode control that resembles a stepper, and status dots without an explained meaning.

### Modality

Settings, capture, prep, diagnostics, and confirmation surfaces use sheets or full-screen covers appropriately in isolation. In aggregate, the app is modal-heavy. Deep actions should prefer navigation when the user is exploring a durable object, and sheets should remain limited to temporary, self-contained work.

### Safe areas, Dynamic Island, and device responsiveness

- The reviewed root dock is placed in a dedicated vertical layout region rather than overlaid on root content, so the earlier bottom-content obstruction is materially improved.
- Capture and Ask use scroll/safe-area behavior that keeps primary controls reachable in the reviewed portrait devices.
- No Dynamic Island or Live Activity integration is present. It is not required for v1, and should not be added for decoration. A recording Live Activity is only worth considering after privacy, background state, battery use, and stop-control behavior are proven on device.
- The target is iPhone-only (`TARGETED_DEVICE_FAMILY = 1`), so iPad responsiveness cannot be approved.
- Landscape orientations are declared in `Info.plist`, but compact-height and landscape layouts were not visually certified. Either test and support them or narrow the declared orientations.

## Visual Design Audit

### Color

Strengths:

- Teal, coral, gold, and neutral surfaces communicate different states without becoming chaotic.
- Dark mode preserves hierarchy and contrast well.
- Recording has a distinct, immersive visual mode.

Issues:

- Teal and dark slate dominate many high-value surfaces, reducing differentiation between navigation, capture, and trust states.
- Very pale disabled text and placeholder text appear low contrast in Quick Note and settings-style panels.
- Accent dots and confidence colors sometimes carry meaning without nearby text.

### Typography and hierarchy

The editorial serif voice is distinctive. It works best for one clear title per screen. It becomes noisy when combined with a large navigation title, uppercase eyebrow, second headline, metric strip, and card title.

Repeated examples:

- Navigation title "Library" + eyebrow "LIBRARY" + headline "All meetings".
- Navigation title "Tasks" + eyebrow "TASKS" + headline "Everything you owe".
- Navigation title "Calendar" + metadata "Calendar" + month title.
- Navigation title "Ask" + repeated "Ask your library" hierarchy.
- Folder navigation title + a second card repeating the folder name.

Recommendation:

Choose one of these patterns per root screen:

- Large native title + compact content summary, or
- Inline native title + one editorial page title.

Do not use both.

### Spacing and density

The app is consistently spaced, but not consistently efficient. Large top regions delay access to saved meetings, tasks, and calendar content. The small-device screenshots expose this most clearly.

Use content density by task:

- Today: concise next action plus immediate agenda.
- Library: dense searchable rows.
- Tasks: dense, scannable status list.
- Calendar: stable grid with compact selected-day agenda.
- Meeting Detail: short overview, then tabs/sections on demand.

### Cards and surfaces

Cards are useful for individual repeated objects and framed tools. Scribeflow also uses them as page sections, header wrappers, metric containers, and nested content groups. This fragments long screens and makes every section demand equal attention.

Reduce full-width surface cards by roughly one third. Prefer separators, section headers, inset grouped lists, and unframed content bands. Keep cards for meeting rows, processing/recovery states, and source-proof objects.

### Iconography and brand assets

SF Symbols are generally consistent and understandable. The custom app icon and brand mark are the weak point:

- The icon's primary symbol occupies too little of the canvas and loses shelf presence.
- The in-app brand mark contains a visible field around detailed artwork, so it looks pasted into small toolbar and splash containers.
- The splash magnifies this issue inside another glass disc.

Recommendation:

Create a bold, full-bleed app icon with one silhouette and strong contrast. Export a separate transparent monochrome or two-tone in-app mark designed to remain crisp from 20 to 64 points.

## Navigation And Flow Audit

### What works

- Root tab state is preserved while switching tabs during a session.
- Detail screens correctly hide the custom dock.
- Library uses a dedicated navigation path for meeting detail.
- Spotlight, notifications, Siri/Shortcuts inbox routing, and deep-link handling exist.
- Re-tapping a root item scrolls its main list to the top.
- Ask's composer uses safe-area placement and is not covered by the dock.

### What does not work well

- Visual tab labels are absent.
- The app always initializes the selected root tab to Today instead of restoring the last meaningful state.
- Several features can be reached from Today, Settings, Meeting Detail, and command surfaces, creating duplicated routes.
- The product has many nested destination types inside very large views, especially Meeting Detail.
- The custom dock behavior is not certified in landscape or compact height.

### Recommended navigation model

- Keep five tabs only if Calendar and Tasks both show meaningful weekly engagement in analytics.
- Make Today the daily decision surface, not a second Library/Tasks dashboard.
- Make Library the canonical owner of saved meeting navigation.
- Make Meeting Detail the canonical owner of source review, transcript, media, and meeting-specific Ask.
- Make Settings the canonical owner of diagnostics, privacy, storage, account, and integrations.
- Remove duplicate feature launchers after analytics confirms the preferred route.

## Accessibility Audit

### Existing strengths

- Important icon-only buttons have accessibility labels.
- Dock items expose labels, values, identifiers, button traits, and selected state.
- Calendar day cells have descriptive labels.
- Source-proof controls expose their confidence and purpose.
- Capture record, pause, language, speaker count, bookmarks, and settings recovery are labeled.
- Reduce Motion and Reduce Transparency are read in core design components.
- Dark mode is coherent and readable in the reviewed primary flow.

### Blocking failures

**Critical: Larger Text layout failure**

- The Today greeting breaks inside a word on an iPhone SE at Accessibility Extra Large.
- Task titles and key metadata truncate until their meaning is lost.
- The hero consumes most of the first viewport and pushes actionable content below it.
- Horizontal metric layouts cannot accommodate enlarged labels cleanly.

**High: unverified VoiceOver order and actions**

- The repository has useful labels, but semantic traversal order was not tested.
- Custom cards, combined accessibility elements, horizontal scrollers, and tab dots require manual verification.
- Gesture actions need named accessibility actions.

**High: possible color-only status**

- Meeting-detail discovery dots and small dock badges need textual/semantic equivalents.
- Confidence and status colors must remain understandable in grayscale and with color filters.

### Required accessibility acceptance criteria

- No primary content truncates at AX5.
- Every root destination has a visible and spoken name.
- Every icon-only action has a concise label and, where needed, a hint.
- VoiceOver can complete onboarding, create a typed note, start/stop a recording, save, open a meeting, inspect a source, complete a task, export a backup, and delete an account.
- Switch Control and Full Keyboard Access can reach every actionable control.
- Reduce Motion removes repeated ambient movement and nonessential transitions.
- Increase Contrast and Differentiate Without Color preserve every state.
- App Store Accessibility Nutrition Label claims are made only after device verification.

## Motion And Interaction Audit

### Strengths

- Motion tokens are centralized.
- Many transitions use short spring/smooth animations rather than arbitrary durations.
- Repeating animation helpers observe Reduce Motion and scene phase.
- The live waveform is isolated so frequent audio-level updates do not intentionally invalidate the entire capture stage.
- Haptics are used for selection, recording, save, and completion feedback.

### Risks

- Splash, breathing dots, entrance cascades, gradients, reactive rings, pulsing timers, shadows, and material effects combine into a high animation budget.
- Several screens animate content that users need to scan rather than content whose spatial change needs explanation.
- `TodayView` contains investor presentation animation code alongside the daily product UI, increasing complexity.
- Material appearance differs between iOS 18 and iOS 26, making the custom chrome less consistent than native controls.

Recommendation:

Reserve motion for state change, hierarchy, and continuity. Remove entrance animation from repeated list rows, stop ambient motion after the first few seconds, and use opacity/position transitions only when they explain where content came from.

## Performance And Stability Audit

### Confirmed positive engineering

- Release simulator compilation succeeds.
- Calendar snapshot building uses an actor.
- Library and Today use precomputed/cached snapshot models.
- Spotlight indexing and some expensive work are detached from the main actor.
- Backup encoding and calendar work have off-main paths.
- Audio-level rendering is intentionally isolated from the capture parent.
- Background processing, retry metadata, recovery, and notification routing exist.
- Animation loops pause when the scene is inactive.

### Concrete defect

**Critical: duplicate SwiftUI identity in Calendar**

`MeetingCalendarView` renders weekday symbols with `ForEach(Self.weekdaySymbols(), id: \.self)`. Single-letter weekday symbols contain duplicate `S` and `T` values, so SwiftUI treats distinct columns as the same identity. The rendered header visibly drops weekdays on both reviewed OS versions.

Fix:

Use enumerated weekday entries or a stable weekday index as identity. Add a regression assertion that exactly seven headers render for every locale and first-weekday configuration.

### Code-backed performance risks

- `MeetingStore` is a 4,785-line `@MainActor @Observable` object shared through the environment. Broad mutations can invalidate large view trees.
- `TodayView` is 4,765 lines and `MeetingDetailView` is 4,311 lines. Large bodies and mixed responsibilities make invalidation and regression analysis difficult.
- `Models.swift`, `CaptureView`, `AppCore`, Calendar, processing, Tasks, Settings, and intelligence files are also over 1,000 lines.
- Many fixed gradients, materials, shadows, and animated overlays can increase compositing cost on older devices.
- Large-detail screens can create many expensive subtrees before the user needs them.
- There are many one- and two-line limits, which hide data problems and create repeated layout recalculation under Dynamic Type.
- Root screens observe the same shared store instead of small feature-specific projections.

### Internal QA defect

When `-SCRIBEFLOW_RESET_DATA` and `-SCRIBEFLOW_USE_SEED_DATA` are passed together, reset wins and seed loading is skipped. That makes the obvious clean-seeded QA launch produce an empty workspace.

Fix:

Define explicit argument precedence: reset persisted files first, then seed when seed is also requested. Keep this behavior in a small QA launch-configuration test.

### Performance acceptance criteria before release

- Record a 60-minute meeting on the oldest supported physical device without thermal termination or data loss.
- Keep scrolling hitch rate within an agreed budget on Today, Library, Calendar, and Meeting Detail.
- Measure launch, hang, memory, energy, and background task completion with Instruments and MetricKit.
- Verify save returns immediately while processing continues safely.
- Verify cancellation and deduplication when a meeting is deleted, retried, or reprocessed.
- Verify the app does not repeatedly recompute intelligence for unchanged persisted data.
- Set a recording-storage policy and test low-disk behavior.

## Screen-By-Screen Audit

| Screen | Score | Status | Main finding |
|---|---:|---|---|
| Native launch | 3.5/10 | Blocker | Blank white frame conflicts with dark branded splash |
| SwiftUI splash | 5.8/10 | Needs redesign | Distinctive but delayed, ornamental, and asset quality is weak |
| Onboarding | 7.5/10 | Good with polish | Clear story; too card-heavy and feature-count oriented |
| Authentication/app lock | 6.5/10 | Needs copy review | Secure options exist; "Sign in to start" conflicts with optional local use |
| Today | 7.2/10 standard, 3.5/10 AX | Blocker | Strong briefing, but oversized and broken at accessibility sizes |
| Library | 7.0/10 | Needs polish | Useful rows and metadata; duplicate hierarchy and copy truncation |
| Tasks | 7.5/10 | Strong | High utility; duplicate hierarchy, chip clipping, and noisy durations |
| Calendar | 5.4/10 | Blocker | Versatile views, but missing weekday headers are immediately visible |
| Ask | 7.4/10 | Strong | Clear scope and source promise; top hierarchy repeats itself |
| Quick Note | 6.6/10 | Needs product correction | Clean editor, but defaults to a sales Discovery template |
| Live Capture | 7.2/10 visual | Device proof required | Immersive and clear; preflight is dense and speech quality unverified |
| Meeting Detail | 7.1/10 | Strong but overloaded | Excellent trust model; very long, dense, and occasionally malformed copy |
| Folder Detail | 5.2/10 | Redesign | Duplicated title, weak summary, stacked cards, ambiguous chat control |
| Settings | 6.9/10 code-backed | Simplify | Comprehensive and transparent, but long and operationally dense |
| Storage and backup | 7.7/10 code-backed | Strong foundation | Excellent user control; CloudKit shipping state must match claims |
| Recording privacy | 8.0/10 code-backed | Strong | Clear limits and opt-in controls; verify every distributed configuration |
| Diagnostics/readiness | 7.0/10 code-backed | Internal strength | Useful support surface; keep user-facing health language simple |

Secondary route assessment (code-backed unless noted):

| Route | Score | Finding |
|---|---:|---|
| Meeting prep | 7.6/10 | Strong source-backed context; keep the join-time brief short |
| Calendar day agenda | 7.2/10 | Useful drill-down; should reuse Calendar density and terminology |
| Library filters | 7.0/10 | Capable, but root chips and sheet filters need one shared model |
| Meeting-specific Ask/chat | 7.3/10 | Valuable scope; "Auto" mode control is visually ambiguous |
| Source inspector | 8.2/10 | Product-defining proof surface; preserve direct source navigation |
| Speaker editor | 7.1/10 | Honest correction path; needs real-device and VoiceOver certification |
| Recording playback/media | 7.0/10 | Complete controls; long-session and missing-file recovery need device proof |
| Meeting presentation | 6.8/10 | Useful for sharing, but not a primary v1 daily workflow |
| Audio diagnostics | 7.4/10 | Good self-service recovery; should stay secondary to automatic fixes |
| Recording privacy | 8.0/10 | Clear processing and call limitations |
| Account/storage status | 7.0/10 | Transparent capability reporting; shipping state must be exact |
| Usage impact | 6.6/10 | Useful optional insight; avoid promoting vanity metrics on Today |
| Integrations | 6.5/10 | Secure HTTPS/Keychain boundary; webhook terminology is technical |
| Activity log | 7.3/10 | Excellent local transparency; raw event names need user-friendly rendering |
| Logout confirmation | 7.2/10 | Clearly explains what remains local |
| Account deletion | 7.4/10 | Required path exists; remote deletion semantics need production proof |
| Legacy saved sheet | 5.0/10 | Current capture flow bypasses it; remove or document its remaining owner |
| Investor presentation | 7.0/10 internal | Useful demo proof, but keep investor-only code out of production UI paths |

These scores are lower-confidence than the rendered primary-screen scores. They identify design and release risk from implementation evidence; they do not replace interactive device review.

### Native launch and splash

Best correction: one matching solid background from native launch to the first interactive screen. Returning users should not wait for brand animation. First-time users can see the mark in onboarding.

### Today

Keep:

- Greeting.
- One next move.
- Up to three priorities.
- Next calendar event.
- Background processing status.

Remove or defer:

- Repeated metrics that are not actionable.
- Oversized decorative space.
- Duplicate paths to the same feature.
- Investor-only visual content from the production view hierarchy.

### Library

Move to a denser Notes-like list. Keep pinned and recent grouping, source/action metadata, search, filters, and folders. Use one title and make Ask a toolbar action instead of a visually competing black button.

### Tasks

This is one of the best product surfaces. Preserve source context and one-tap completion. Replace exact second-level durations with rounded human language, explain overlapping attention counts, and ensure chips do not appear accidentally clipped.

### Calendar

The Month/Week/Agenda model is right. After the identity fix:

- Match Apple's familiar date geometry and locale behavior.
- Offer compact, stacked, and detail density where useful.
- Keep the selected-day agenda close to the grid.
- Make event-to-note creation the primary differentiation.
- Test landscape because the app declares it.

### Quick Note and Capture

Quick Note should open as a neutral blank note. It should not require a meeting objective or work template. Suggested structure can appear after the user writes enough context, and the app can ask whether to organize it as a meeting, personal note, idea, journal, or task.

Live Capture should begin with one dominant record control. Title, attendees, expected speakers, language, and template can live in a compact preflight drawer. Replace "Auto voices" with "Detect speakers automatically" and shorten the attendee placeholder.

### Meeting Detail

The ideal first viewport contains:

- Title, date, people, and purpose.
- One-sentence bottom line.
- Processing/trust state.
- Next action.
- A clear route to transcript and sources.

Move detailed statistics, scorecards, prep, presentation, integrations, media management, and diagnostics behind progressive disclosure. Keep source proof near every generated claim.

### Folder Detail

Replace the large summary card stack with:

- Compact folder title and count.
- Search/filter/sort toolbar.
- Optional one-paragraph folder summary generated from all contained notes.
- Native meeting rows.
- Bottom Ask composer scoped to the folder.

Do not use the first meeting's raw calendar notes as the folder summary.

## Visual Consistency Review

### Consistent elements

- Teal accent, coral risk color, gold attention color, and neutral surfaces.
- Serif display headings and monospaced metadata.
- SF Symbol usage.
- Reusable radius, spacing, shadow, motion, and material tokens.
- Source-proof language and confidence treatment.
- Root screen horizontal margins.
- Dark appearance behavior.

### Inconsistent elements

- Native navigation titles coexist with custom editorial titles.
- Black, teal, gradient, glass, and bordered primary buttons all compete as primary styles.
- Material rendering changes noticeably between iOS 18 and iOS 26.
- Some screens are dense lists while others wrap every section in a large card.
- Durations vary between concise labels and exact "mins, secs" strings.
- Status language varies between "Good local read", confidence labels, inferred labels, and source counts.
- Toolbar brand assets, splash assets, and the app icon do not feel like the same optimized symbol family.
- Calendar, Tasks, and Library use different filter affordances for similar list-scoping behavior.

### Design-system correction

Define four visual layers and enforce them:

- Canvas: page background only.
- Navigation: native or one custom chrome treatment.
- Section: unframed grouping with title and separator.
- Object: card/list row for one meeting, task, event, proof, or recovery state.

Define three action levels:

- Primary: one filled action per screen.
- Secondary: bordered or tinted text action.
- Tertiary: icon or menu action.

Do not introduce a fourth style for the same semantic priority.

## Copy And Microcopy Audit

### Voice strengths

The best copy is direct, calm, and accountable:

- "Saved. Refining in background."
- "No account required."
- "Recording stays on this device."
- "Source proof."
- "Note type needs review."
- "Verify important information."

This tone should become the product standard.

### Copy problems

**High: generated and seed text is visibly malformed**

Examples observed in the rendered app included grammatically incomplete summaries and an intelligence metadata line beginning with "Risks attendees...". Even when limited to sample data, these defects teach investors and reviewers not to trust the core output.

**High: personal capture uses work-specific language**

Quick Note defaults to Discovery, whose guidance refers to buyer pain, intent signals, and next steps. A personal reflection should not visually begin as a sales meeting.

**Medium: internal vocabulary reaches users**

- "Auto voices" is implementation language.
- "Good local read" is friendly but ambiguous.
- "Securing" does not explain whether the app is saving audio, finalizing a transcript, or encrypting data.
- "Copilot recall" in a placeholder is feature marketing inside a data-entry field.
- "Everything you owe" is memorable but can feel accusatory in personal use.

**Medium: excess metadata reduces comprehension**

Strings such as topic, domain, confidence, source count, speaker count, template, and purpose appear in one line. The user should not need to decode a diagnostic sentence.

### Recommended terminology

| Current | Recommended |
|---|---|
| Auto voices | Detect speakers automatically |
| Expected voices | Expected speakers |
| Good local read | High confidence, processed on device |
| Securing | Saving recording / Finalizing transcript, based on actual state |
| Everything you owe | Open actions |
| Copilot recall | Find related context |
| Note type needs review | Review note type |
| Discovery template for Quick Note | General note |

### Output-quality gate

Before showing generated text:

- Reject fragments without a subject or useful predicate.
- Reject repeated labels and duplicated prefixes.
- Round durations for display.
- Validate owner/date combinations.
- Keep a source-backed sentence verbatim enough to verify, while paraphrasing summaries clearly.
- Mark an item inferred only when the source does not state it directly.
- Suppress work-only categories for personal notes unless the user explicitly converts the note to a meeting/work context.
- Run the same renderer against seed data, local heuristic output, Apple Intelligence output, and backend output.

## Feature-By-Feature UX Review

### Authentication and app lock

Status: **Good foundation, confusing positioning**

- Local use without an account is a privacy and conversion strength.
- Device sign-in, Sign in with Apple, Keychain storage, app lock, logout, and account deletion paths exist.
- "Sign in to start" implies an account requirement even though the local workspace does not require one.
- Treat biometric protection as "App Lock", not as a sign-in product unless a real account service is active.

### Capture and import

Status: **Feature complete, too much preflight**

- Record, type, audio import, calendar-linked capture, notes, bookmarks, language, and speaker expectations are covered.
- The capture form should reveal advanced context progressively.
- Quick Note needs a neutral default.
- Imported audio should state file limits, supported formats, processing location, and recoverable failure state before import.

### Speech and speaker detection

Status: **Architecturally promising, quality unverified**

- The code supports contextual vocabulary, locale selection, local and remote provider boundaries, retry, transcript revisions, expected speaker count, and on-device speaker separation metadata.
- The UI honestly exposes no-label and inferred states.
- No simulator review can validate recognition accuracy, crosstalk, accents, distance, noise, Bluetooth routes, long sessions, or true speaker count.
- Do not market "accurate speaker detection" until a representative physical-device corpus has objective word-error and diarization-error measurements.

### Meeting intelligence

Status: **Differentiated and trustworthy, occasionally overproduced**

- Purpose-aware extraction and conservative personal-note handling are strategically correct.
- Source proof and confidence should remain the product center.
- The app should generate fewer, better claims instead of filling every section.
- Personal notes should default to summary/themes, not tasks, risks, owners, or business scorecards.
- Work-meeting output should prioritize decision, owner, date, and source over decorative scores.

### Tasks and reminders

Status: **One of the strongest features**

- Open actions, at-risk items, due dates, source meeting, owners, completion, and Reminders export form a meaningful accountability loop.
- Make overlapping counts explicit so totals cannot appear contradictory.
- Use a simple Inbox/Today/Upcoming/Done model before adding more filters.
- Reminder authorization and test-alert status are good; actual delivery still needs device certification.

### Calendar

Status: **Strong concept, current visible blocker**

- Month, week, agenda, content filters, event linking, prep, and capture are meaningful.
- The weekday identity bug makes the primary visual unshippable.
- Calendar access recovery is well surfaced.
- The next improvement is density/familiarity, not another calendar mode.

### Ask and recall

Status: **Clear value, needs tighter scope controls**

- The current scope and source-backed expectation are visible.
- Suggested prompts reduce blank-state anxiety.
- Ask at Library, folder, and meeting scope is useful, but each scope must be labeled consistently.
- Answers should lead with a direct response, then sources; model/provider status should remain secondary.

### Search and organization

Status: **Broad, but folders are weak**

- Search, filters, pinned notes, grouping, Spotlight, tags/metadata, and folders exist.
- Folder Detail does not yet match the quality of Library.
- Make saved filters or smart collections only after basic folder summary and row density are fixed.

### Share and export

Status: **Strong user control**

- Meeting digest, source proof, backup export, restore preview, recordings, and user-directed webhooks are considered.
- Every outbound flow should preview exactly what leaves the device and where it goes.
- Review metadata must not imply automatic Slack/Notion/Linear delivery when only a user-configured webhook exists.

### Backup and deletion

Status: **Strong local foundation, configuration-sensitive cloud layer**

- Manual backup, notes-only/full export, automatic local snapshots, restore preview, cleanup, delete-all, and account deletion are valuable.
- The CloudKit entitlement file exists, but `CODE_SIGN_ENTITLEMENTS` is not wired in the target project settings.
- The shipping UI and public policy must not claim a working private iCloud backup until the signed profile, container, schema, and production behavior are verified.

### Notifications and background completion

Status: **Good states, delivery unverified**

- Permission status, test alert, ready notification, reminder scheduling, background identifiers, and deep-link routing exist.
- A simulator build is insufficient proof.
- Test with the app foregrounded, backgrounded, suspended, force-quit, device locked, notification denied, Focus enabled, and after reboot.

### Empty, loading, and error states

Status: **Good coverage, inconsistent presentation**

- Skeletons, empty hints, access cards, retry paths, processing cards, banners, and diagnostics are present.
- Use one recovery pattern across the app: what happened, what is safe, primary fix, secondary details.
- Avoid surfacing raw localized error descriptions as the only user guidance.

## Premium Product Benchmark

The goal is not to imitate another app's appearance. It is to adopt the interaction discipline that makes each benchmark feel dependable.

### Apple Notes

What to learn:

- A blank note starts instantly and does not ask the user to classify intent first.
- The first line can become the title.
- Rich structure stays available but does not block capture.
- Folders, pinning, tags, search, and collapsible sections scale from quick notes to long documents.

Scribeflow advantage:

- Better source-backed meeting intelligence, action ownership, transcript, and follow-through.

Required response:

Make Type mode as immediate as Notes. Intelligence should organize after capture, not make the user configure the note before writing.

### Apple Reminders and Things

What to learn:

- Show only what is actionable now.
- Use familiar Today, Upcoming/Scheduled, Inbox, and Completed mental models.
- Keep advanced properties tucked away until needed.
- Preserve clear ownership and one-tap completion.

Scribeflow advantage:

- Every task can retain meeting, speaker, and source evidence.

Required response:

Reduce summary metrics and filters until the next action is unmistakable. Source context should be one tap away, not consume every row.

### Apple Calendar and Fantastical

What to learn:

- Familiar month/week/list geometry lowers cognitive load.
- Different density options serve planning and scanning.
- Natural-language creation reduces form work.
- Calendar and tasks can coexist without turning the calendar into a dashboard.

Scribeflow advantage:

- An event can become a prepared, recorded, source-backed meeting record.

Required response:

Fix calendar identity, match locale and layout expectations, then make "prepare or capture this meeting" the unique value.

### Apple Journal

What to learn:

- Personal writing is not treated as project management.
- Suggestions are optional prompts, not mandatory categories.
- Privacy and app lock are part of the emotional experience.
- Search and calendar browsing support reflection without adding work language.

Scribeflow advantage:

- Spoken personal notes can become searchable memory with source audio.

Required response:

Add a General/Personal capture posture and suppress tasks, risks, scores, and owners unless the content truly supports them.

### Apple Photos

What to learn:

- Content remains primary while collections, search, filters, and density controls support large libraries.
- Curated summaries lead to the complete source rather than replacing it.
- People can pin and reorder frequently used collections.

Scribeflow advantage:

- Text, audio, people, tasks, and decisions can be searched semantically.

Required response:

Treat meetings as the primary content. Use collections and summaries as lenses, not as competing cards layered over the library.

### Notion and Craft

What to learn:

- Documents, tasks, search, and connections can coexist when the object model is clear.
- Craft demonstrates that personal and work notes can share a system without forcing the same output on both.
- Notion demonstrates the power and risk of a broad workspace: capability expands quickly, but simplicity can disappear.

Scribeflow advantage:

- It is purpose-built around captured conversation and evidence rather than an empty workspace framework.

Required response:

Protect that focus. Do not become a generic workspace, database builder, or automation canvas in v1.

### Linear

What to learn:

- Use plain terminology.
- Keep ownership, status, filtering, and next action immediately scannable.
- Start simple and reveal power progressively.
- Purpose-built workflows outperform endless customization for daily work.

Scribeflow advantage:

- It can connect commitments to the actual conversation that created them.

Required response:

Remove diagnostic jargon and ornamental metrics from primary screens. Let evidence and action state carry the product.

## App Store Readiness Assessment

### Functionality and completeness: 62/100

Passes:

- Release simulator build succeeds.
- Core local workflow is implemented.
- Permission recovery and diagnostics exist.
- Local workspace does not require an account.
- A first-run example prevents a completely empty product.

Blocks:

- Visible Calendar defect.
- Larger Text failure.
- Real-device capture and background flow not certified.
- Production provider and CloudKit capability state not certified.
- Signed archive and App Review installation not tested.

### Design quality: 72/100

Passes:

- Distinct visual identity.
- Cohesive color and typography.
- Strong dark mode.
- Excellent trust surfaces.

Blocks:

- Weak icon/brand mark at small size.
- Launch discontinuity.
- Repeated title hierarchy.
- Card and motion overuse.
- Folder screen below the rest of the product.

### User experience: 67/100

Passes:

- End-to-end workflow is understandable.
- Save/background processing model is appropriate.
- Tasks, sources, calendar prep, and Ask create real utility.

Blocks:

- Capture preflight is too dense.
- Personal use begins in a work template.
- Icon-only tab navigation is less discoverable.
- Meeting Detail is overloaded.
- Copy defects weaken confidence.

### Accessibility: 48/100

Passes:

- Strong semantic labeling effort.
- Reduce Motion/Transparency support exists.
- Core controls generally meet minimum target dimensions.

Blocks:

- Primary UI fails Larger Text visibly.
- VoiceOver, Switch Control, contrast, and color differentiation are not certified.
- Landscape and compact height are not certified.

### Performance: 66/100 provisional

Passes:

- Snapshot caching, actors, detached work, and leaf isolation show deliberate optimization.
- Background and recovery architecture exists.

Blocks:

- No trace data.
- Large observable store and very large view files increase invalidation risk.
- Visual effects and long detail trees need profiling on old devices.

### Stability: 64/100 provisional

Passes:

- Release simulator compilation succeeds.
- Persistence backup/recovery and processing retry paths exist.

Blocks:

- No physical-device long recording, interruption, notification, migration, or low-storage certification.
- No signed archive validation.
- Calendar identity is a concrete runtime rendering bug.

### Privacy and legal: 76/100

Passes:

- Privacy manifest declares no tracking and lists required-reason APIs.
- Public Privacy Policy and Terms URLs are live.
- Recording consent and AI fallibility are disclosed.
- Local activity log, export, delete-all, logout, and account deletion exist.

Blocks:

- Privacy Policy permission table omits Reminders even though the app requests Reminders access.
- Public iCloud language must match the entitlement and production configuration actually shipped.
- App Store privacy answers must be generated from the exact Release capability matrix.
- Terms and policy still need qualified legal review for launch territories.

### Metadata and presentation: 50/100

Known issues:

- App icon lacks small-size impact.
- No App Store Connect listing, localized description, keywords, age rating, support URL package, screenshot set, preview, or review notes were audited.
- Screenshots must show real product use and accurate capability states.
- Demo/sample data must be clearly fictional and free of malformed intelligence output.

### Final launch readiness: 58/100

Interpretation:

- 90-100: ready to submit.
- 80-89: submit after final smoke and metadata review.
- 70-79: TestFlight candidate with known polish work.
- 60-69: internal beta; major release risks remain.
- Below 60: do not submit publicly.

Scribeflow is at the top of the pre-submission/internal-beta range, but the visible Calendar and accessibility failures keep the public decision at NO-GO.

## Prioritized Action Plan

### Critical - P0 public-release blockers

#### Fix Calendar identity and locale correctness

Evidence: missing weekday symbols on both reviewed OS versions.  
Implementation: use weekday index identity, test seven columns for every locale/first weekday.  
Exit criterion: no duplicate-ID warnings and seven correct headers in Month and Week views.

#### Rebuild core layouts for Larger Text

Evidence: broken greeting and truncated task meaning at Accessibility Extra Large.  
Implementation: semantic type styles, adaptive stacks, remove primary-content line limits, accessibility-specific density.  
Exit criterion: onboarding, Today, Capture, Library, Tasks, Calendar, Ask, Meeting Detail, Settings, backup, and deletion remain usable through AX5.

#### Certify capture, save, processing, and notification on physical devices

Evidence: architecture exists, but simulator cannot prove microphone/speech/background behavior.  
Implementation: device matrix covering long sessions, noise, Bluetooth, interruptions, force quit, denied permissions, low storage, and retry.  
Exit criterion: no data loss, UI stall, duplicate meeting, orphan audio, or false completion notification.

#### Align every capability claim with the signed Release binary

Evidence: CloudKit entitlement template exists but is not wired with `CODE_SIGN_ENTITLEMENTS`; production transcription needs configured service proof.  
Implementation: either enable/profile/deploy/verify each capability or hide it and narrow public copy.  
Exit criterion: UI, policy, App Store privacy answers, screenshots, review notes, and runtime readiness report all agree.

#### Remove malformed intelligence and sample copy

Evidence: incomplete summary grammar and malformed topic metadata are visible.  
Implementation: output validation, seeded fixture review, renderer consistency checks.  
Exit criterion: every shipped sample and generated fallback passes a human copy checklist.

#### Create a continuous launch experience

Evidence: blank white native launch then dark animated splash.  
Implementation: matching native background, no mandatory returning-user delay, optimized transparent mark.  
Exit criterion: no light/dark flash and first interaction is available immediately.

### High priority - P1 product polish

- Add visible root destination labels or return to the native tab bar.
- Make Type mode a neutral General note with title inferred from the first line.
- Collapse Meeting Detail to bottom line, trust, next action, transcript, and sources.
- Redesign Folder Detail as a compact searchable list.
- Remove duplicate navigation/editorial titles on every root screen.
- Standardize primary, secondary, tertiary, destructive, and disabled actions.
- Replace internal speech/AI jargon with user language.
- Restore last root tab and meaningful navigation state.
- Add Reminders to the Privacy Policy permission disclosure.
- Redesign app icon and in-app mark as separate assets.

### Medium priority - P2 measured quality and maintainability

- Establish launch, scroll, memory, energy, and background-processing budgets.
- Run Instruments on the oldest supported iPhone and a current device.
- Split `TodayView`, `MeetingDetailView`, and `MeetingStore` by feature responsibility.
- Give root screens narrow immutable snapshots instead of broad shared-store observation.
- Physically organize source into App, Core, DesignSystem, Features, Services, and Resources in small Xcode-safe moves.
- Add automated accessibility identifiers and smoke flows for every primary route.
- Add snapshot coverage at small iPhone, standard iPhone, dark mode, and AX5.
- Fix reset-plus-seed QA argument precedence.
- Complete String Catalog coverage before localization claims.
- Decide whether declared landscape support is intentional; either certify it or restrict orientation accurately.

### Low priority - P3 nonblocking polish

- Remove exact-second duration wording from all list and detail metadata.
- Standardize empty-state illustration/icon sizing.
- Simplify investor-only animation and presentation code boundaries.
- Tune minor shadow/radius differences after the primary surface hierarchy is fixed.
- Add optional collection-density preferences only after the default layout is excellent.

### Future enhancements - post-launch expansion

- Ship private iCloud backup only after profile/schema/device proof.
- Add widgets and App Intent surfaces for next meeting, open actions, and quick capture.
- Add smart collections only after folders and search are stable.
- Add measured speech-language packs and device-specific recognition guidance.
- Add team/collaboration features only after the local personal product reaches retention targets.
- Consider iPad and Mac after the iPhone object model and sync contract are stable.

## Redesign Recommendations

### Root shell

- Use a native labeled tab bar with Today, Library, Tasks, Calendar, and Ask.
- Keep one persistent, familiar navigation system.
- Put Settings in the Today toolbar and global search in Library/Ask.
- Let each root retain scroll and navigation state.

### Today

- Inline header: greeting and date.
- Primary block: next meeting or next action.
- Secondary block: up to three open priorities.
- Tertiary block: processing and calendar permission only when relevant.
- One compact capture button or toolbar action.
- Move historical metrics to Usage Impact.

### Capture

- First screen: Record/Type segmented control, title/first line, and dominant record/editor area.
- Advanced drawer: attendees, speaker expectation, language, template, objective.
- General should be default; suggest a template after context exists.
- During recording: timer, input health, live draft, mark, pause, stop.
- After stop: close immediately after durable save; process in background.

### Meeting Detail

- Header: title, date, people, purpose edit.
- Overview: bottom line, next action, trust state.
- Tabs: Overview, Actions, Transcript, More.
- Put source buttons inline with each claim.
- Lazy-load deep intelligence, prep, score, presentation, and media tools.
- Remove unexplained discovery dots.

### Library and folders

- Use a compact searchable list by default.
- Keep Pinned, Recent, and processing groups.
- Display title, date, people/source status, and one useful follow-up count.
- Use folder summary only when it represents the entire folder and shows its source basis.

### Design system

- Replace fixed display sizes with semantic text roles.
- Reduce radius and shadow variety.
- Use one surface material per platform generation where possible.
- Remove entrance motion from repeated rows.
- Define minimum contrast and AX5 layout fixtures for every component.
- Create content-state components for loading, empty, unavailable, recoverable error, and destructive confirmation.

### Architecture

Recommended long-term physical structure:

```text
Scribeflow/
  App/
  Core/
    Models/
    Persistence/
    Intelligence/
  DesignSystem/
  Features/
    Today/
    Capture/
    Library/
    Tasks/
    Calendar/
    Ask/
    MeetingDetail/
    Settings/
  Services/
    Audio/
    Speech/
    Notifications/
    Calendar/
    Backup/
    Integrations/
  Resources/
```

Move files gradually so project membership, storage compatibility, and current uncommitted work remain intact. The immediate architectural objective is not folder cosmetics; it is smaller observation domains, pure transformation engines, stable persistence contracts, and independently testable feature state.

## Version Roadmap

### Version 1.0 - Stabilize and submit

Product scope:

- Local-first Record and Type capture.
- Durable save and background refinement.
- Purpose-aware summary with source proof.
- Speaker review without accuracy overclaim.
- Library, open actions, calendar context, and Ask.
- Export, local backup/recovery, deletion, privacy, diagnostics.

Required work:

- Close every P0 item.
- Complete physical-device QA and signed archive validation.
- Produce accurate App Store metadata and review notes.
- Submit only capabilities that are actually configured.

Do not add:

- Collaboration.
- Generic workspace databases.
- Additional dashboard metrics.
- More meeting templates before General/Personal works perfectly.

### Version 1.1 - Clarity and accessibility

- Native/labeled navigation decision.
- Neutral Quick Note and adaptive personal-note output.
- Meeting Detail progressive disclosure.
- Folder redesign.
- Full Larger Text and VoiceOver certification.
- Copy and terminology cleanup.
- Performance budgets and regression dashboard.
- Widgets/App Intents for quick capture and open actions if device metrics are healthy.

### Version 1.2 - Reliable connected workflows

- Production private iCloud backup after entitlement/schema proof.
- Production transcription provider behind the existing abstraction, with explicit opt-in and retention disclosure.
- Measured multilingual recognition guidance.
- Better Calendar/Reminders handoff and reviewable webhook destinations.
- Smart collections and saved search based on real user behavior.
- iPad discovery/build decision based on demand.

### Version 2.0 - Shared meeting memory

Only pursue after retention proves the local product:

- Cross-device library with conflict-safe sync.
- Shared meeting records and explicit participant permissions.
- Team ownership and acknowledgement of actions.
- Organization-level source permissions and audit history.
- Mac/iPad companion experiences.
- Provider-independent intelligence evaluation and admin controls.

Version 2.0 should expand the ownership model, not turn Scribeflow into a generic project-management suite.

## Final Verdict

### Top five strengths

- Source-backed AI is visible and editable.
- Purpose-aware handling is more thoughtful than a generic work summarizer, especially when it remains conservative for personal notes.
- Local-first storage, backup, deletion, app lock, and public limitation language form a credible privacy model.
- Capture, review, follow-through, calendar prep, and recall form a complete daily-use loop.
- The recording stage, dark mode, recovery architecture, and provider boundaries show a distinctive product and serious engineering intent.

### Top weaknesses

- Core accessibility layouts fail at Larger Text.
- Calendar has a visible identity bug in the main grid.
- Launch screen, splash, icon, and mark do not form a continuous premium brand experience.
- The custom icon-only dock sacrifices discoverability for style.
- Root screens repeat titles and use too much first-viewport space.
- Quick Note begins with the wrong work-specific mental model.
- Meeting Detail and Settings expose too much at once.
- Folder Detail does not meet the quality bar of Library or Tasks.
- Generated/sample copy defects damage trust in intelligence.
- Release capabilities and real-device behavior are not yet certified.

### Approval decision

**Public App Store submission: not approved today.**

**Controlled investor demonstration: conditionally approved** after the Calendar header, malformed sample copy, launch flash, and primary Larger Text defects are corrected.

**Internal/TestFlight beta: appropriate** after physical-device capture/save/notification smoke tests pass and every distributed capability is accurately disclosed.

The product does not need to become larger. It needs to become quieter, more adaptive, and more provably reliable. The shortest path to a premium launch is to preserve the source-backed core, remove visual and conceptual repetition, make personal capture genuinely neutral, and certify the complete workflow on real devices.

## Evidence Pointers

Key repository evidence:

- `Scribeflow/MeetingCalendarView.swift:285` - duplicate weekday string identity.
- `Scribeflow/TodayView.swift:491` - primary Today hero and adaptive-text failure area.
- `Scribeflow/DesignTokens.swift:704` - custom root dock metrics and implementation.
- `Scribeflow/ContentView.swift:211` - icon-only root destinations and custom dock placement.
- `Scribeflow/CaptureView.swift:39` - Discovery default for all capture modes.
- `Scribeflow/CaptureView.swift:143` - persisted template fallback to Discovery.
- `Scribeflow/Models.swift:25` - templates have no General/Personal option.
- `Scribeflow/MeetingDetailView.swift:628` - meeting-detail tab picker and discovery dots.
- `Scribeflow/MeetingStore.swift:213` - reset/seed argument precedence.
- `Scribeflow/ScribeflowApp.swift:282` - animated splash implementation.
- `Scribeflow/Info.plist:57` - empty native launch-screen dictionary.
- `Scribeflow/SettingsView.swift:38` - public support and legal URLs.
- `Scribeflow/PrivacyInfo.xcprivacy:5` - privacy manifest declarations.
- `Scribeflow/Scribeflow.entitlements:7` - CloudKit container template.
- `Scribeflow.xcodeproj/project.pbxproj:637` - version/build and target settings; no wired `CODE_SIGN_ENTITLEMENTS` found.
- `Scribeflow/SOURCE_MAP.md:106` - known large-file split candidates.

Current external guidance used:

- [Apple HIG: Tab bars](https://developer.apple.com/design/human-interface-guidelines/tab-bars)
- [Apple HIG: Accessibility](https://developer.apple.com/design/human-interface-guidelines/accessibility)
- [Apple HIG: Typography](https://developer.apple.com/design/human-interface-guidelines/typography)
- [Apple HIG: Launching](https://developer.apple.com/design/human-interface-guidelines/launching)
- [Apple App Review Guidelines](https://developer.apple.com/app-store/review/guidelines/)
- [Apple Larger Text evaluation criteria](https://developer.apple.com/help/app-store-connect/manage-app-accessibility/larger-text-evaluation-criteria)
- [Apple Notes: Quick Notes](https://support.apple.com/guide/iphone/iph5084c0387/26/ios/26)
- [Apple Notes: Create and format notes](https://support.apple.com/en-gb/guide/iphone/iph1ac0b3a2/26/ios/26)
- [Apple Reminders: Smart Lists](https://support.apple.com/en-ie/guide/iphone/iphe882772ed/ios)
- [Apple Calendar: Change event views](https://support.apple.com/en-lamr/guide/iphone/iphfd1054569/26/ios/26)
- [Apple Journal: Get started](https://support.apple.com/en-ca/guide/iphone/iph0e5ca7dd3/ios)
- [Apple Photos: Browse collections](https://support.apple.com/en-ie/guide/iphone/iph4f36c4148/26/ios/26)
- [Things: Today and Upcoming](https://culturedcode.com/things/support/articles/4001304/)
- [Fantastical: Adding events and tasks](https://flexibits.com/fantastical/help/adding-events-and-tasks)
- [Craft](https://www.craft.do/)
- [Notion product](https://www.notion.com/product)
- [Linear principles](https://linear.app/method/introduction)

Public product disclosures checked:

- [Scribeflow Privacy Policy](https://jaskaranchana.github.io/meeting-notes/PRIVACY)
- [Scribeflow Terms of Use](https://jaskaranchana.github.io/meeting-notes/TERMS)

## Closing Executive Summary And Step-By-Step Roadmap

Would I approve the current build for public App Store release? **No.** The Calendar identity defect, Larger Text failure, launch discontinuity, capability uncertainty, and missing physical-device certification are release blockers.

Does it already feel premium? **In selected moments.** Source proof, Tasks, dark mode, capture, privacy, and recovery can feel premium. Repeated headings, card density, malformed copy, the icon-only dock, and weak brand assets make the full product feel less resolved than those best moments.

Would users enjoy it daily? **Meeting-heavy users could, after stabilization.** The core loop is useful enough for daily behavior, but personal-note framing, accessibility failures, pre-capture ceremony, and unproven long-session reliability would currently exclude or frustrate important users.

Transformation sequence:

1. Fix the seven-column Calendar identity defect and every malformed shipped sample/output string.
2. Rebuild primary layouts through AX5 and complete VoiceOver task-flow certification.
3. Prove record, save, background processing, speaker review, notifications, recovery, and deletion on physical devices.
4. Align CloudKit, transcription, privacy, screenshots, and review claims with the exact signed Release configuration.
5. Replace the blank native launch transition and create production-grade app-icon/in-app-mark assets.
6. Make Quick Note neutral and move meeting configuration into progressive disclosure.
7. Adopt labeled native navigation or make the custom dock equally discoverable and fully adaptive.
8. Remove duplicate titles, reduce cards/motion, and redesign Meeting Detail and Folder Detail around progressive disclosure.
9. Profile the oldest supported device, set performance budgets, and split the largest observation/view domains without changing storage contracts.
10. Produce the signed archive, App Store metadata, fictional review data, accessibility claims, and final review notes; then run the submission smoke matrix.

After these steps, Scribeflow has a credible path from **58/100** launch readiness to the low-to-mid 80s without adding another major feature. The product should earn reliability first, then connected services, then broader collaboration.
