# MacVoxCPM

Native macOS app for [VoxCPM](https://github.com/OpenBMB/VoxCPM) — a tokenizer-free,
multilingual text-to-speech model from OpenBMB. SwiftUI front-end with an embedded
Python sidecar that runs the official `voxcpm` package and downloads the
`openbmb/VoxCPM2` model from Hugging Face on first launch.

## What you get

- **Text → speech** in 30 languages, 48 kHz output.
- **Voice Design** — describe a voice in natural language.
- **Voice Cloning** — drop in a short reference clip.
- **Ultimate Cloning** — reference clip + transcript for max fidelity.
- **Advanced Settings** sheet (CFG, inference timesteps, seed, device, …) tucked
  behind one button so the main UI stays simple.

## Requirements

- macOS 15 Sequoia or newer (built and tested against macOS 26 SDK).
- Apple Silicon recommended (PyTorch MPS).
- ~8 GB free disk on first launch (Python venv + VoxCPM2 weights).
- Internet on first launch to download `uv`-managed Python, `voxcpm`, and the model.

## Build

```bash
./scripts/fetch-uv.sh                 # downloads pinned uv binary into Resources/
./scripts/build-app.sh                # produces build/stage/MacVoxCPM.app
open build/stage/MacVoxCPM.app
```

For day-to-day dev:

```bash
swift run MacVoxCPM
```

## Layout

```
Sources/MacVoxCPM/
  App/        @main + AppState
  Views/      SwiftUI screens (Onboarding, Generator, AdvancedSettings, ...)
  Models/     Plain Swift data types
  Services/   SidecarManager, AudioStore, Storage
  Resources/  uv binary + sidecar python source (populated by fetch-uv.sh and build script)
sidecar/      Source-of-truth Python (FastAPI server wrapping voxcpm)
```
