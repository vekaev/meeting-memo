# Meeting Memo: working rules

**Record the meetings you choose. Nothing else.** Keep it that small: every feature must defend its place against that line.
It never records without a click, never uploads, never edits the calendar.

A menu-bar-only Mac app (`LSUIElement`, `MenuBarExtra` in window style):

| | Where |
|---|---|
| App, menu, settings, prompt card | `App/` (`App.swift`, `MenuView.swift`, `SettingsView.swift`, `PromptPanel.swift`, `AppController.swift`) |
| Recording, calendar, settings store (no SwiftUI) | `Core/` (`Recorder.swift`, `CalendarWatcher.swift`, `Store.swift`) |
| Info.plist | generated from `project.yml` (`info.properties`); edit it there, not in `App/Info.plist` |
| Scheme | `MeetingMemo` (product "Meeting Memo", bundle id `com.yevheniipetrenko.MeetingMemo`) |

Mac only on purpose: iPhone/iPad can't capture another app's call audio. See the parity table.

## Every change: build, restart, verify, push

1. Build:
   ```bash
   xcodegen generate
   xcodebuild -project MeetingMemo.xcodeproj -scheme MeetingMemo -configuration Debug -derivedDataPath build -quiet build
   ```
2. Restart the app with the new build when a change is done, without asking:
   ```bash
   scripts/install-mac.sh     # builds Release, quits the running copy normally, installs to ~/Applications, reopens
   ```
   It re-signs with the local Apple Development identity so macOS keeps the Calendar, Microphone and
   Screen & System Audio permissions across builds (ad-hoc signatures would reset them every time).
3. Verify on screen. The menu is a `MenuBarExtra` window, which computer-use screenshots filter out (the app
   isn't in the installed-apps list): open it with a `computer_batch` click on the menu-bar icon, then capture
   with `screencapture -x -R…` from Bash in the next call. Any further computer-use call closes the menu.
   Find the icon first with a `screencapture` of the menu bar; its position moves after every relaunch.
   Report what was and wasn't seen.
4. Commit and push each finished fix to `main`; update the README and the parity table.

## Design

Minimal, monochrome, Apple-like. The menu-bar item is one template image drawn in `MenuBarLabel.swift`
(five-bar waveform, the app icon's mark; dot + monospaced timer while recording, width reserved so it never
changes). The menu reads like a native menu: few icons, rows highlight on hover, a thin ring before each row that
starts a recording (red dot under the pointer), secondary text for dates, red only for "recording" and "Now". The prompt card is a non-activating panel at status-bar level in the
top-right corner of the screen under the pointer, so it never steals focus and Stage Manager or a second
display can't hide it. Its look: light grey card with a soft multicolour rim, bold title + grey "now",
attendee initials, grey "Ignore" and a black primary button with a red record dot. Call cards say where
("on Zoom", "on Google Meet") and ask once per call; only known call apps count, so Siri, dictation or a
notetaker using the mic never trigger one. The card's Screen switch is drawn by hand (`CardSwitchStyle`): the
system switch turns grey on a non-key panel. Settings live in their own window, Granola-like: hidden title bar,
a sidebar (Meetings, Recording, Reminders, General), rounded groups of rows with a title, a grey description and
the control on the right; a meeting is a one-line summary that expands to edit in place.

## Method (installed skills)

Decisions are the owner's, facts are the agent's. Open design questions → `grilling` (rounds of numbered
questions, each with a recommended answer). Terms → `GLOSSARY.md`, decisions with reasons → `docs/adr/`
(`domain-modeling`). Logic in `Core/` → `tdd` at agreed seams, with a `swiftc` harness over `Core/*.swift`.
API facts (EventKit, ScreenCaptureKit) → `research`. "It's broken" → `diagnosing-bugs`. Before a release →
`code-review`, then `references/release.md` of the bootstrap-app skill. After a long session → `retro`,
folded back into this file.

## Owner's data

Recordings in `~/Documents/Meeting Recordings` and the owner's calendar are read-only for tests. Never create
calendar events or start a recording to test without asking first. Test file operations on copies in the
scratchpad.

## Parity table

| Feature | Mac | iPhone / iPad |
|---|---|---|
| Record mic + call audio | ScreenCaptureKit + mic | n/a: iOS can't capture other apps' audio |
| Screen video (.mov next to the .m4a) per meeting, switch on the card, chosen display or main | `SCRecordingOutput` on the same stream | n/a |
| Prompt at meeting start / end (attendees, snooze 5 min) | floating card on the pointer's screen | n/a |
| Saved card (Show in Finder, Open, Delete → Trash) | prompt panel, auto-closes | n/a |
| Local transcript (.md next to the recording) | `Core/transcribe.py` (MLX Whisper via `uv`), `Transcriber.swift` | n/a |
| Card on joining / leaving a call (Zoom, Meet, Teams…) | CoreAudio per-process mic use + window titles (`CallWatcher.swift`) | n/a |
| Next reminder time, "Record?" while a card waits | menu, menu-bar icon | n/a |
| Meetings with next date, open in Calendar | menu-bar menu | n/a |

## Debugging

- Transcription: `uv run --script` on the bundled `transcribe.py` (afconvert → 16 kHz mono → Whisper
  large-v3-turbo on MLX), `HF_HUB_OFFLINE=1` once the model is cached. Its output goes to
  `~/Library/Application Support/MeetingMemo/transcribe.log`. Test it on speech made with `say`, never on the
  owner's recordings.

- Errors go to `NSLog("MeetingMemo: …")`; in this shell `log` is shadowed:
  `/usr/bin/log show --last 5m --style compact --predicate 'eventMessage CONTAINS "MeetingMemo:"'`.
- Settings: `~/Library/Application Support/MeetingMemo/settings.json`. In-progress call recordings:
  `~/Library/Application Support/MeetingMemo/In Progress/`.
- Opening one event in Calendar uses the undocumented `ical://ekevent/<id>?method=show&options=more`
  (recurring events: `ical://ekevent/<yyyyMMddTHHmmssZ>/<id>…`); it falls back to opening Calendar.
