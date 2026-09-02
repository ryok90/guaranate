---
title: Install
description: Install Guaranate with Homebrew, from a release binary, or from source.
---

Guaranate requires **macOS 14 or later** and runs natively on Apple Silicon and
Intel.

## Homebrew

```bash
brew tap ryok90/guaranate
brew install guaranate
```

## Release binary

Download the universal (`arm64` + `x86_64`) build from the
[latest release](https://github.com/ryok90/guaranate/releases/latest), verify its
checksum, and put it on your `PATH`:

```bash
shasum -a 256 -c guaranate-*-macos-universal.tar.gz.sha256
tar -xzf guaranate-*-macos-universal.tar.gz
cp guaranate-*-macos-universal/guaranate /usr/local/bin/   # or anywhere on your PATH
```

Verifying the checksum before extracting is the point of publishing it — don't
skip it.

## From source

Building requires Swift 6 (Xcode 16 or later):

```bash
git clone https://github.com/ryok90/guaranate.git
cd guaranate
swift build -c release
cp .build/release/guaranate /usr/local/bin/   # or anywhere on your PATH
```

## Confirm the install

```bash
guaranate --version
guaranate 5          # a five-second session
```

The five-second run acquires a real power assertion and releases it on exit, so
it is also the quickest end-to-end check that installation worked. To watch the
assertion appear and disappear, see [How it works](/guides/how-it-works/).
