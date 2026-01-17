# Archibald

Archibald is a floating, audio-reactive **Grok Voice Agent** client for macOS.
Add your xAI (Grok Voice Agent) API key and talk to Grok from anywhere on your
desktop, with conversation history saved automatically.

## Download

- Latest DMG: [Download Archibald.dmg](https://github.com/jamesrisberg/archibald/releases/latest/download/Archibald.dmg)

## Features

- Always present not-too-ominous orb that reacts to audio.
- Global hotkey to show and start listening.
- Configurable voice and system prompt.
- Conversation transcript saved per session.
- Optional shared inbox folder for context.

## Requirements

- macOS 13+
- xAI (Grok Voice Agent) API key

## Setup

1. Download and open the DMG.
2. Move `Archibald.app` to Applications.
3. Launch the app and open **Settings** from the menu bar.
4. Paste your **XAI Voice Agent API Key**.
5. Grant microphone permissions when prompted.

## Keyboard Shortcut

Default: **Option + \\**  
You can change this in **Settings → System**.

## Transcripts

Each session transcript is saved to:

`~/Library/Application Support/Archibald/Transcripts`

You can open the folder or clear the current transcript from **Settings**.

## Local Build / Release

Run a local signed + notarized release build:

```
APPLE_TEAM_ID="YOUR_TEAM_ID" \
APPLE_ID="you@appleid.com" \
APPLE_APP_SPECIFIC_PASSWORD="xxxx-xxxx-xxxx-xxxx" \
./scripts/release-local.sh
```

The DMG will be created at `build/Archibald.dmg`.

## Support

Support the project: [Stripe](https://buy.stripe.com/6oU5kDfq5g512861bedwc00)
