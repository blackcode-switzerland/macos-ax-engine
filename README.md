# macos-ax-engine

Reading and driving macOS programs through the Accessibility API
(`AXUIElement`), without screenshots: read the controls, act on one, read
again to verify.

This repository is at its first step: a trial that answers one question.

## The trial

Can a command-line tool, started from a shell, read another program's
controls and press a button, and whose Accessibility permission does macOS
apply to it?

- `probe/main.swift`: the probe. It starts the fixture itself, reads its
  window, presses a button, replaces the content of a text field, reads the
  menu bar and triggers a menu entry. Every result is checked twice: by
  reading the control again, and against a state file written by the fixture.
- `fixture/main.swift`: a small AppKit program with a button, a label, a text
  field, a password field, a checkbox and a menu.
- `.github/workflows/trial.yml`: builds both on GitHub's macOS machines and
  runs the probe in four ways (directly from the shell step, as a child of
  another program, from inside an app bundle, and through the system
  launcher).

## Build and run on a Mac

Needs Xcode or Apple's command-line developer tools (`xcode-select --install`).

```sh
bash scripts/build.sh
./build/axprobe trial --fixture "$PWD/build/axfixture" --out "$PWD/out/direct" --textedit
```

The program that starts the probe (for example Terminal) must be allowed
under System Settings > Privacy & Security > Accessibility.

## The test kit: one command

```sh
curl -fsSL https://raw.githubusercontent.com/blackcode-switzerland/macos-ax-engine/main/kit.sh | bash
```

It fetches this source into a temporary folder, builds it on your Mac, starts
the fixture, runs the checks, prints a pass/fail table and packs the logs
into one file in the folder you ran it from. It takes no picture of the
screen and touches only the fixture it starts itself, and TextEdit only if
TextEdit is not already open. Read `kit.sh` first; it is short.

## Rules the engine will keep

- It acts only on programs it started itself.
- It never reads or fills password fields.
- It does not start browsers or command shells.

## Licence

MIT, see `LICENSE`.
