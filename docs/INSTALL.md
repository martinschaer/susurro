# Susurro — install (private beta)

Susurro transcribes everything you say and hear, locally, and puts a waveform in your
menu bar. Nothing leaves your machine.

## Before you start

- **macOS 14.2 or newer.** The system-audio capture uses Core Audio process taps, which
  do not exist before 14.2.
- **Apple Silicon.** The build is `arm64` only — an Intel Mac cannot run it at all.
- **~3 GB of disk** for the speech models, and a connection to download them once.

## 1. Install

Unzip `Susurro.zip` and drag `Susurro.app` to `/Applications`.

## 2. Get past Gatekeeper

This beta is ad-hoc signed, not notarised, so the first launch is blocked with
*"Apple could not verify Susurro is free of malware."*

- **macOS 15 and later:** click **Done**, then System Settings ▸ Privacy & Security,
  scroll to the bottom, and click **Open Anyway** next to Susurro.
- **macOS 14:** right-click the app ▸ **Open**, then **Open** again.

To skip the dialog altogether, run this once before the first launch:

```bash
xattr -dr com.apple.quarantine /Applications/Susurro.app
```

There is no Dock icon — Susurro is a menu bar app. Look for the `waveform.slash`
icon at the top right.

## 3. Download the models

Click the menu bar icon ▸ **Download models (2.8 GB)…**

The menu shows which file is in flight. It takes a while. It is resumable and safe to
re-run: if it fails, or you quit halfway, open the menu and click it again — it picks up
where it stopped. Failures are logged to `~/.susurro/models-download.log`.

## 4. Turn it on

Click the menu bar icon ▸ **Listening**.

Two permission prompts follow — microphone first, then system audio. Both are required;
Susurro records your voice from the mic and everyone else's from the audio your Mac is
playing. If you miss a prompt, grant it in System Settings ▸ Privacy & Security ▸
**Microphone** and ▸ **Screen & System Audio Recording**.

The first time you switch on, macOS compiles the model for the Neural Engine — about
30 seconds, once. The menu says *Loading model…* while it does. Later launches are instant.

Listening is deliberately **off** at every launch. An always-on recorder that resumes
silently on login is worse than one you have to switch on.

## Where everything lives

| | |
|---|---|
| Transcripts | `~/.susurro/transcripts` — one JSONL file per meeting, `0700` |
| Models | `~/.susurro/models` |
| Voiceprints | `~/.susurro/speakers.json` — how a voice is recognised again, `0600` |
| Speaker names | a `name` field on the transcript's own lines |
| Meeting in progress | `~/.susurro/live` — moved into `transcripts` when it ends |
| Settings | `~/.susurro/config.json` — optional, every key has a default |

Menu ▸ **Open transcripts…** opens the folder. Menu ▸ **Name speakers…** puts real names on
the `user-N` voices, one meeting at a time, with a sample of what each one said to help you
tell them apart.

**Names belong to one meeting.** `user-4` is a voice the app learned to recognise, not a
person — over weeks it will sometimes file two people under one `user-N`, so a name that is
right in Tuesday's call can be wrong in Friday's. Naming somebody changes that meeting and
no other. What it does do is remember: the next time that voice turns up, the names you have
already used are offered as suggestions, with the most-used first.

## Known rough edges

1. **Use headphones.** On speakers, your mic hears the call audio too, so everything is
   transcribed twice — and your own voice also enrols as a system speaker.
2. **Permissions may be asked again** each time you install a new beta build. That is the
   ad-hoc signature changing; notarisation fixes it and is not done yet.
3. **Battery.** An eight-hour day of large-v3-turbo on the Neural Engine is real power draw.
4. **No crash recovery.** Audio buffered but not yet transcribed is lost on quit or crash.

## One thing to be aware of

Susurro records other people in your calls. In many places that needs their agreement.
That is your call to make, not the app's.

## Reporting something

Include your macOS version and the build (Finder ▸ Susurro.app ▸ Get Info ▸ Version).
If it is a download problem, `~/.susurro/models-download.log` has the detail.
