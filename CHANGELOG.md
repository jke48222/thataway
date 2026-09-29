# Changelog

All notable changes to Thataway are listed here, newest first. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and versions will follow
[Semantic Versioning](https://semver.org/spec/v2.0.0.html) once the first release is out.

No version has been released yet. Everything below is what you get today by building `main` from
source.

## [Unreleased]

### Added

- Press Option Space, type or say the name of a control, and a drawn pointer arcs from your mouse
  to it in the app you are using. Your cursor stays where it is, and nothing is clicked.
- A live shortlist of the top three matches under the bar, updated on every keystroke.
- Solid rings for exact answers, dashed amber rings with a question mark for guesses, and no
  pointer when nothing matches. Spoken answers carry the same hedge.
- Push-to-talk: hold Option Space to speak, tap it to type. Speech is recognized on your Mac, US
  English only.
- An optional vision fallback that runs H Company's Holo1.5-7B on your Mac when the accessibility
  tree has no answer. You install the model and a Python with `mlx_vlm` and Pillow yourself.
- An exclusion list at `~/.config/thataway/exclusions.conf`, checked before an app is read. It
  starts with 26 app rules and 16 window-title rules covering password managers, banks, Messages,
  Mail, Notes and health apps, and reloads when you save it.
- A stated refusal in the bar when the app in front is excluded, naming the reason.
- Two built-in lessons, "Open this app's settings" and "Find something in this app", which move on
  when the app shows you did the step. Next Step and Previous Step are in the Teach Me… menu.
- Watch me: record a few clicks from Teach Me…, Record a Workflow, and replay them as a lesson.
- Menu bar items and items inside an open menu can be pointed at.
- Pointer coordinates are converted between displays, so a second screen with a different origin
  or scale gets the right position.

### Changed

- The app is now called Thataway. The first run moves your settings folder to
  `~/.config/thataway`.
- The vision model's frame now holds only the target app's windows. It goes to the model in
  memory, and the fallback temp file is readable only by you and deleted after the reply.

### Fixed

- A late vision answer no longer takes the keyboard from the app you moved on to.
- Lessons stay on the app they started in, and captions fit on screen.
- Exclusion files saved with Windows line endings are read correctly.
- Recorded steps replay exactly as recorded.
- A recorded step now waits only for something replay can see arrive. Before, it could wait for a
  sheet titled "Advanced Options" that already matched the "Advanced Options..." button before the
  click, or for a sheet titled "Open", whose name matches nothing, and sit until its two-minute
  timeout.
- The refusal for an excluded app says "exclusion list" once and names the rule, for example "Not
  looking at TextEdit: the app is on the exclusion list (bundle: com.apple.textedit)."
- Fixes to the hotkey, voice turns, the overlay and the lesson runner.

[Unreleased]: https://github.com/jke48222/thataway/commits/main
