# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

Encrypted, serverless P2P messaging over a Bluetooth LE mesh, with an optional
Nostr relay fallback. Flutter; Android and iOS are the real targets (web and
windows build for UI work but have no BLE). `landing/` is a separate React + Vite
marketing site with its own `package.json`.

`lib/core/` holds transport, crypto, ble, storage, theme and shared widgets.
`lib/features/<name>/{data,models,domain,presentation}` holds the rest — `data/`
is Riverpod `Notifier` controllers. `README.md` documents the protocol and the
threat model in full.

## Commands

`flutter` is on PATH via `~/.bashrc`.

```bash
flutter test test/mesh_ttl_test.dart
```

```bash
flutter analyze
```

```bash
flutter gen-l10n
```

APKs are built by `tool/build_apk.ps1`, never by `flutter build apk` — that
command is broken in this repo and a hook blocks it.

## Skills — load these rather than reconstructing the rules

- **`wire-protocol`** — anything under `lib/core/transport/**` or `lib/core/crypto/**`: tag namespaces, envelope layout, adding a payload, peer-id epochs.
- **`release-build`** — building an APK or IPA, version and stamp, installing on a phone, CI.
- **`flutter-testing`** — running or writing tests, goldens, Hive and Riverpod harnesses.
- **`glass-ui`** — screens, widgets, colours, blur, animation.
- **`perf-triage`** — heat, battery, lag: which instrument answers which question.

## Two rules that cost the most when broken

**IMPORTANT: read the comment above a constant before changing it.** This tree
records experiments that were measured and reverted — refresh rate in
`main.dart`, blur sigma in `glass.dart`, the `pro_image_editor` pin in
`pubspec.yaml`. Re-proposing one of them is the most common failure here.

**IMPORTANT: load the `wire-protocol` skill before changing anything on the
wire.** A colliding tag byte produces no compile error and no failing test; it
ships and breaks phones that already have the app installed.

## Conventions

- Commit subjects are a sentence about the effect, not a conventional-commits
  prefix: "Stop the read-receipt storm that ate the phone and the log".
- Comments explain why, and carry the measurement that justified the change. Add
  one when you revert something, too.
- Measure before optimising. The wins here were GPS and uncapped image decodes,
  not blurs and not signing.
- `MessagingService` is ~8k lines and reaches every controller through
  `_ref.read`. Work there is additive; do not extract a subsystem in passing.
- Analyzer runs strict: `strict-casts`, `strict-inference`, `strict-raw-types`,
  `prefer_final_locals`, `require_trailing_commas`.
