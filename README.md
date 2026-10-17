# Skycast

An ad-free weather app. One Flutter codebase, two targets: Android and web.

**Live web version: https://amihali1.github.io/skycast/**

Built because every mainstream weather app is now an ad delivery vehicle with a
forecast attached. Skycast has no ads, no trackers, no accounts, and no API keys.

## Features

- Current conditions with feels-like, humidity, and wind
- 24-hour forecast strip with precipitation probability
- 8-day daily forecast
- City search (Open-Meteo geocoding)
- °F / °C toggle, remembered between sessions
- Weather-reactive background gradients (day/night aware)

## Data

All weather data comes from [Open-Meteo](https://open-meteo.com/) — a free,
open-source weather API that requires no key and serves no ads.

## Development

```sh
flutter run -d chrome     # run in browser
flutter run -d android    # run on device/emulator (needs Android SDK)
flutter test              # widget tests
```

## Builds

```sh
flutter build web --release   # output in build/web — deployable to any static host
flutter build apk --release   # Android APK (needs Android SDK)
```
