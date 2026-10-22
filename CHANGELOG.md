# Changelog

## v0.1.1 — 2026-10-21

Fixes from the first real install on another computer, where the install folder was inside Dropbox:

- Install refuses cloud-synced folders (Dropbox, OneDrive, Google Drive, iCloud, Box) and asks for a local one. Sync clients lock files while thousands of them are written, which left the Python packages incomplete.
- An install, update or rollback now ends by checking that every Python package is really installed, then writes an "install complete" marker. "Start ComfyUI" refuses to start without it and says to run Install / Repair, instead of showing a Python traceback.
- Doctor checks the install folder and the Python packages, and shows the last error from the most recent install, update, rollback or download, with the lines that explain it.

## v0.1.0 — 2026-10-19

First version. Tested pins (manifest `2026.10.19`):

| Component | Version |
|---|---|
| ComfyUI | v0.42.1 (`63be2f9b`) |
| ComfyUI-for-Nuke | v1.4 (`c81be1e4`) |
| ComfyUI-VideoHelperSuite | main @ `4d907bee` |
| ComfyUI-HQ-Image-Save | main @ `44b0c6f7` |
| Python | 3.12.13 |
| PyTorch | 2.14.1 cu130 (driver ≥ 580), 2.11.0 cu128 (RTX 50 with driver 570–579), 2.14.1 cu126 (older GPUs), 2.14.1 cpu |
| uv | 0.13.1 |
| MinGit | 2.56.0.2 |

macOS (`install.sh`, Apple Silicon, macOS 14+): same repos and Python, PyTorch 2.14.1 from PyPI (MPS), uv 0.13.1 (aarch64), git from Apple Command Line Tools.

Features: install / repair, per-item updates with restore points and rollback, Doctor support zip, logs with retention, isolation from other Python installs, shortcut icons, the Downloads model sorter (`model_sorter.py`) and "Download missing models" with resume (`model_download.py`).
