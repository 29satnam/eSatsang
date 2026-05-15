# eSatsang iOS App

A minimal, VoiceOver-first iOS app for listening to live eSatsang streams.

## The Story

My mom has an iPhone 6S. Apple dropped support for it in iOS 16, which meant she could no longer update TestFlight — the app needed to download the official eSatsang app. The phone was headed for the bin.

Instead of throwing it away, I decided to put my skills to use.

I built this app specifically for her: stripped down, no clutter, no unnecessary features. Just open it, tap Play, and listen. Everything is designed around VoiceOver — large tap targets, meaningful accessibility labels, lock screen controls, and automatic resume after phone calls. No overhead, no navigation maze, nothing that gets in the way for someone using touch and low vision.

It took a retired phone and gave it one job. It does that job well.

## Features

- **One-tap playback** — login once, tap Play every time after
- **Audio & video streams** — plays audio or inline video depending on what the stream provides
- **VoiceOver focused** — every control labelled, lock screen & Control Centre support
- **Interruption handling** — auto-resumes after phone calls, Siri, and alarms
- **Buffering feedback** — shows status while the stream loads, auto-recovers from stalls
- **Credentials saved securely** — Keychain + Password AutoFill on login
- **Minimal by design** — no features that don't serve the listener

## Requirements

- iOS 15+ (runs on iPhone 6S)
- An active eSatsang account

## Data Sources

The API and stream data used by this app are sourced from:

- [shabds/esatsang](https://github.com/shabds/esatsang)
- [web.esatsang.live](https://web.esatsang.live/)

## Rights & Copyright

All content, audio streams, and associated data are the property of:

**© Ra Dha Sva Aa Mi Satsang Sabha, Dayalbagh, Agra UP 282005 INDIA**

This app is a personal, non-commercial client built solely to access the service on unsupported hardware. It does not host, redistribute, or modify any content.

## Built With

SwiftUI · AVFoundation · AVKit · MediaPlayer · Security
