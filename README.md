# NextAI Translator Native

A native macOS SwiftUI edition of NextAI Translator. It keeps the desktop workflow—streaming AI translation, selection lookup, OCR, writing replacement, Microsoft Edge Neural TTS, history, vocabulary, custom actions, shortcuts, and a menu-bar controller—without a browser extension or embedded web runtime.

## Requirements

- macOS 14 or newer
- Swift 6.2 or newer
- An API key for the selected provider, or a local Ollama server
- Accessibility permission for selected-text lookup and writing replacement
- Screen Recording permission when using screenshot OCR

## Build and run

```bash
./scripts/test.sh
./scripts/run.sh
```

`run.sh` launches the signed app bundle rather than SwiftPM's raw executable.
macOS binds Accessibility consent to that application identity, so grant access
to the bundled app shown in System Settings.

Create a signed app bundle, ZIP, and DMG:

```bash
./scripts/package-app.sh
open ".build/NextAI Translator Native.app"
```

`scripts/toolchain-env.sh` selects the installed SDK that matches this Mac's Swift
toolchain. This avoids a known mismatch between the current Command Line Tools
compiler and its default SDK symlink.

## Security

- API keys are stored in the macOS Keychain, not `UserDefaults`.
- Provider endpoints must use HTTPS. Plain HTTP is accepted only for loopback Ollama endpoints.
- Endpoint URLs containing embedded credentials are rejected.
- Selection context is bounded before it enters an AI prompt and is explicitly treated as untrusted data.

## License

This project is a native derivative of NextAI Translator and is distributed under AGPL-3.0-or-later. See `LICENSE` and `NOTICE`.
