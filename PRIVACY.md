# Privacy Policy

**Scribeflow**
_Last updated: 15 July 2026_

Scribeflow is local-first. This policy explains what the app stores, what it accesses, and the user-controlled situations in which data may leave your device.

## The short version

- Recordings, transcripts, notes, and action items are stored **locally on your device** by default.
- Scribeflow **does not collect, sell, or share** your personal data, and **does not track** you across apps or websites.
- Data leaves your device only when you export or share it, enable private iCloud backup, use Apple services, send to a webhook you configured, or explicitly enable a configured remote transcription service.

## What Scribeflow stores (on your device)

- **Recordings and transcripts** of meetings and voice notes you capture.
- **Notes, action items, decisions, and summaries** generated from them.
- Your Keychain-backed local or Apple identity session and preferences.

This data lives in the app's protected container. Using **Settings > Delete account** removes local data and, when configured, requires remote account and private cloud deletion to succeed before reporting completion.

Each capture has a source-retention choice. When a selected deadline expires,
Scribeflow deletes the saved transcript and recording while preserving the
user's notes. The policy is enforced while the app runs and again on its next
launch.

## Permissions Scribeflow requests

| Permission | Why | 
|---|---|
| **Microphone** | To record meetings and voice notes you choose to capture. |
| **Speech recognition** | To turn recordings into searchable transcripts (see below). |
| **Calendar** (optional) | To pre-fill meeting titles and link a capture to the right event. Read-only; never modified. |
| **Reminders** (optional) | To add an action item to the Reminders list you choose. Scribeflow writes only after you request it. |
| **Notifications** (optional) | To tell you when a saved capture finishes processing or when a follow-up is due. |
| **Face ID** (optional) | To unlock your session locally. |

You can decline any permission and still use the rest of the app. Permissions are requested only when the related feature is used.

## Speech recognition

By default, transcription uses Apple's **Speech** framework. When on-device recognition is available, processing occurs on the device. Apple may process speech according to its own service terms when on-device recognition is unavailable.

If enhanced on-device transcription or speaker separation is enabled, the app
may download model assets over the current internet connection on first use.
Recordings are not uploaded as part of that model download. Scribeflow falls
back to Apple Speech during Low Power Mode, thermal pressure, or low storage.

Some builds may offer **Remote transcription** under Recording privacy. It is off by default and requires explicit activation. When enabled, future recording audio is encrypted in transit and sent to the configured Scribeflow transcription service. Before enabling this feature in a distributed build, the service retention period, subprocessors, deletion behavior, and App Store privacy disclosures must be published and kept current. If the option is not shown, the service is not configured.

## Apple Intelligence

When available, Scribeflow uses Apple's on-device foundation models to draft summaries and answer questions about your meetings. This processing happens on your device; Scribeflow does not send your content to any server for this.

## User-directed backup, sharing, and webhooks

When private iCloud backup is available in the installed build, it stores a user-requested notes-only backup in the private CloudKit database associated with the user's Apple account. Recordings remain on the device unless the user exports them. The control is hidden when the required signed capability is not configured. Manual export and system sharing send only the content and destination the user selects.

Webhook integrations are off until the user adds an HTTPS endpoint. The full endpoint URL is stored in Keychain. Scribeflow sends a recap only after the user chooses that destination from a meeting. The receiving service then handles the sent content under its own terms and privacy policy.

## Analytics & tracking

Scribeflow includes no advertising or cross-app tracking SDKs and does not use the Advertising Identifier. The optional local activity log is off by default and is erased immediately when disabled. Apple MetricKit diagnostics are stored in a bounded local archive and leave the device only when you explicitly export them. App Store privacy answers must match the capabilities enabled in the distributed build.

## Children

Scribeflow is not directed at children under 13 and does not knowingly collect data from them.

## Changes

If this policy changes, the "Last updated" date above will change and the new version will be posted here.

## Contact

Questions about this policy or your data: **jaskaran.chana1302@gmail.com**
