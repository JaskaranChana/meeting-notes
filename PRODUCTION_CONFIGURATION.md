# Scribeflow Production Configuration

Scribeflow remains local-first when no production values are provided. Never put
API secrets, signing certificates, refresh tokens, or CloudKit credentials in
the repository.

## Transcription Backend

Set these generated Info.plist values through an `.xcconfig` using the
`INFOPLIST_KEY_` prefix, or use the raw names as Debug process environment values:

- `INFOPLIST_KEY_SCRIBEFLOW_API_BASE_URL` - HTTPS base URL. Debug also permits localhost.
- `INFOPLIST_KEY_SCRIBEFLOW_TRANSCRIPTION_PATH` - defaults to `/v1/transcriptions`.
- `INFOPLIST_KEY_SCRIBEFLOW_API_REQUIRES_AUTH` - defaults to `true`.

The backend remains off until the user explicitly enables Remote transcription
under Recording privacy. The app then sends `POST multipart/form-data` with an
`audio` file part, `diarization=true`, `speaker_labels=true`, an
`Idempotency-Key`, and a backend-issued bearer token. Social identity tokens and
device-only sessions are deliberately not accepted as API credentials.

Expected response:

```json
{
  "text": "Complete transcript",
  "diarizationAvailable": true,
  "segments": [
    {
      "speaker": "Speaker 1",
      "text": "Transcript segment",
      "startTime": 0.0,
      "endTime": 4.2
    }
  ]
}
```

The decoder accepts camelCase or snake_case time and diarization keys. Speaker
labels may be strings or numbers; the client normalizes common forms such as
`SPEAKER_00`, `speaker-1`, and numeric labels into stable display names. Return
ordered segments whenever possible. Scribeflow stores these segments with the
recording so names, people counts, and source-backed speaker contributions are
not lost when the note is saved.

`diarizationAvailable` means the provider actually ran speaker separation. Do
not set it merely because a single generic segment was returned. When the field
is absent, the client conservatively treats two or more distinct labels as
speaker-separated output. Apple Speech fallback remains a single mixed track.

The service should enforce authentication, idempotency, upload limits, retention,
rate limits, request tracing, and permanent deletion. The client retries only
transient failures and falls back to Apple Speech.

Remote account deletion uses authenticated `DELETE /v1/account`. It must revoke
sessions and remove all server-owned recordings, transcripts, integrations, and
derived data before returning success.

## Private iCloud Backup

Set `INFOPLIST_KEY_SCRIBEFLOW_CLOUD_BACKUP_ENABLED=true` only after all of these are complete:

- Container `iCloud.ai.scribeflow.app` exists in Apple Developer.
- The app provisioning profile contains the matching iCloud entitlement.
- The entitlement file is wired to the intended build configuration.
- The `ScribeflowBackup` schema and fields are deployed to production.
- Save, restore, conflict, account-change, integrity, and deletion paths pass on devices.

This feature stores one user-controlled private backup package. It is not live
record-level sync. The client prevents unseen remote backups from being silently
overwritten and verifies downloaded data with SHA-256.

## Privacy And App Review

- Update App Store privacy responses before enabling any remote transcription.
- Keep the privacy policy aligned with retention and deletion behavior.
- Provide App Review with the prepared demo mode and any required account notes.
- Confirm recording always has explicit user action and a visible indication.
- Publish accessibility support only after the full device checklist passes.

## Continuous Integration

`.github/workflows/ios-build.yml` compiles unsigned Debug and Release simulator
apps and runs the core test target on pushes to `main` and pull requests. It
does not capture screenshots or run device-only microphone, notification,
accessibility, performance, archive, or restore certification.
