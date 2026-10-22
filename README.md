# ComfyNuke

One-click install, update and rollback of [ComfyUI](https://github.com/comfyanonymous/ComfyUI) and its Nuke plugin [ComfyUI-for-Nuke](https://github.com/vinavfx/ComfyUI-for-Nuke), on Windows and macOS.

- **Nothing needs to be installed first.** Git (Windows), uv and Python are downloaded into the install folder as private copies. The Python and Git you may already have are never used or changed.
- **No admin rights needed.**
- **Nothing upgrades by itself.** Every version is pinned in `versions.json` (tested versions). "Check for updates" lists what can be updated, with a risk note, and you pick what to update.
- **Everything can be rolled back.** Before every install, update or rollback a restore point is saved (git commits, Python packages, `menu.py`).
- **Everything is logged.** Each run writes a log and ends with a list of what was installed, updated, backed up or removed.

## Quick start (Windows)

1. Download `ComfyNuke.zip` from [Releases](../../releases/latest) and unzip it.
2. Double-click `ComfyNuke.bat` and choose **1 Install / Repair**.
   - When it asks where to install, pick a **local folder that is not synced**, such as `C:\ComfyNuke` or `D:\ComfyNuke`. Dropbox, OneDrive, Google Drive and iCloud folders lock files while they sync, which leaves the install incomplete (and would upload many GB of models), so ComfyNuke refuses them and asks for another folder.
   - If Windows says "Windows protected your PC", click "More info" → "Run anyway".
3. When it is done:
   - Double-click **Start ComfyUI** on the desktop and keep that black window open.
   - Open Nuke. The node menu now has **ComfyUI**; click **Update all ComfyUI** the first time.
4. For updates, rollbacks or problems, open **ComfyNuke** from the Start menu.

| Option | What it does |
|---|---|
| Install / Repair | First install; later runs only put back missing pieces and never upgrade anything |
| Check for updates | Lists what can be updated and how risky it is; you choose |
| Roll back | Returns to any earlier restore point |
| Doctor | Checks the setup (including whether every Python package installed), shows the last error with the lines that explain it, and creates a zip on the Desktop (logs and settings only) to send to whoever helps you |
| Uninstall | Removes the Nuke menu and plugin (moved to a backup folder); models are kept |
| Download missing models | Downloads every model a workflow still needs, straight into the right folders, with a progress bar; resumes after a closed window or a shutdown |
| Sign in to Hugging Face | Saves or replaces your Hugging Face token (Install also asks for it once, at the start) |

### Hugging Face token

Most models come from Hugging Face, which needs a free account and an access token. Install asks for it at the start (press Enter to skip), so the rest of the install can run unattended:

**Create the token (once):**

1. Go to [huggingface.co](https://huggingface.co) and sign up (free) or sign in.
2. Click your profile picture (top right) → **Settings** → **Access Tokens** → **+ Create new token**.
3. Token type: **Fine-grained**. Token name: anything, for example `comfynuke`.
4. Presets: **Read-Only**. Under "Applies to", keep only your own account (do not add organizations).
5. Click **Create token** and **copy** it right away; Hugging Face shows it only once. It starts with `hf_`.
6. In ComfyNuke, paste it when asked (Install, option 9, or option 8) and press Enter. Nothing appears on screen while you paste; that is normal.

**Models with a lock icon** also need their licence accepted once: click the 🔗 next to the model in ComfyUI's "Missing Models", sign in on that page and click the agree button. The token does not need to change for this.

Never share the token. If it leaks, delete it on the Access Tokens page and create a new one.

ComfyNuke checks the token with Hugging Face straight away, shows which account it belongs to, and warns if it can also write (a Read-only token is safer). It is saved where every Hugging Face tool looks for it, `%USERPROFILE%\.cache\huggingface\token` (`~/.cache/huggingface/token` on a Mac), readable only by your user account. It is never stored in an environment variable, in ComfyNuke's own files or in any log. "Status" shows who you are signed in as. Uninstall leaves the token alone; delete it on huggingface.co if you no longer need it.

### If ComfyUI won't start

"Start ComfyUI" only runs after an install that finished and was verified. If it says the install is not finished, or ComfyUI stops with an error such as `ModuleNotFoundError`, open ComfyNuke and choose **1 Install / Repair**: it continues where the last attempt stopped. If that fails again, choose **6 Doctor**; it shows the last error, and the lines just above it usually say why (for example a cloud-synced install folder, or a company network blocking downloads).

## Quick start (Mac)

Apple Silicon (M1 or later) and macOS 14 or later only: PyTorch no longer supports Intel Macs.

Open Terminal, paste this and press Enter:

```bash
curl -fsSL https://raw.githubusercontent.com/amsyeung/comfyui-nuke-setup/main/install.sh | bash -s install
```

Or unzip `ComfyNuke.zip` and run `bash install.sh` in that folder. The options are the same as on Windows.

| | Windows | Mac |
|---|---|---|
| Git | Private MinGit | Apple Command Line Tools (free; you are asked before it installs) |
| PyTorch | CUDA (picked for your graphics card) or CPU | Apple GPU (MPS) |
| Install folder | `C:\ComfyNuke` | `~/ComfyNuke` |
| Logs | `%LOCALAPPDATA%\ComfyNuke\logs` | `~/Library/Logs/ComfyNuke` |
| Start ComfyUI | "Start ComfyUI" on the desktop | "Start ComfyUI.command" on the desktop |
| Tool menu | "ComfyNuke" in the Start menu | `~/ComfyNuke/ComfyNuke.command` |

## What works right after installing

No API key or account is needed. After installing you have:

- ComfyUI running locally on your own graphics card, and the ComfyUI menu inside Nuke.
- Nodes to send Nuke images and sequences to ComfyUI and bring the results back (VideoHelperSuite), including EXR (HQ-Image-Save).

What is **not** included is the AI models themselves. They are large files (often 2–25 GB each) that you download once per workflow; see the next section.

- **Open models are free**, but some ask you to accept their licence on Hugging Face first (a lock icon in ComfyUI), and some do not allow commercial use, so check each model's licence before using it for work.
- **Cloud models cost money.** ComfyUI's "API nodes" (for example ByteDance Seedance, Google Veo, Kling) run on paid services and need a Comfy account with credits. You only pay if you use those nodes.

How far you can go locally depends on your graphics card memory (VRAM): about 8 GB is enough for image models such as SDXL, while video models usually want 16 GB or more.

## Downloading models

When you open a workflow or template, ComfyUI lists anything it still needs under **Missing Models** (on the right). There are two ways to get them:

| | ComfyUI's Download buttons (in the browser) | ComfyNuke → **8 Download missing models** |
|---|---|---|
| Best for | Small files and quick tries | **Large files (about 5 GB and up)**, or after a browser download failed |
| Where files go | Your Downloads folder; the sorter (below) moves them into place while "Start ComfyUI" is running | Straight into the right `ComfyUI\models` folder |
| If the connection drops | Often fails near the end and starts again from zero | Choose 8 again: it continues where it stopped, even after closing the window or a restart |
| Progress | The browser's download list | A progress bar with size, speed and time left |

**Why big files fail in the browser:** Hugging Face gives the browser a download link that expires after about an hour. A 15 GB file takes longer than that, and if the connection blips after the link has expired, the browser cannot continue ("File wasn't available on site" / "Forbidden"). Option 8 asks for a fresh link every time it reconnects, so this does not happen.

### Using option 8 (no model names to type)

1. In ComfyUI, open the workflow and press **Ctrl+S** to save it. (Or skip this and, in option 8, press **S** and type a few words of the *template* name, such as `klein 9b distilled`.)
2. Open **ComfyNuke** from the Start menu and choose **8**, then pick the workflow by its number. ComfyNuke reads the model names and folders from the workflow itself.
3. Check the list (files, sizes, folders, free disk space) and press Enter to start.
4. When it says **Done**, go back to ComfyUI and press **R** to refresh. The Missing Models list should be empty.

If anything needs your action (usually a licence to accept), it is listed again at the very end under **Needs your action**, and ComfyNuke offers to open the page in your browser. Click the agree button there, then choose 8 again. Partial downloads wait in `ComfyUI\models\.comfynuke-downloads` until they finish. Its log is `*-model-download.log` in the logs folder.

### When a download goes wrong

| What you see | Why | What to do |
|---|---|---|
| A big browser download fails near the end ("File wasn't available on site", "Forbidden") | The download link expired during a long download | Use option 8 for that model |
| "Download all" starts only one file | The browser blocks several downloads at once from one site | Allow "Automatic downloads" for `http://127.0.0.1:8188` (small icon at the right of Chrome's address bar, or Settings → Privacy and security → Site settings → Automatic downloads), or click each Download button |
| A lock icon, or "needs its licence accepted" | The model's licence has not been accepted on this Hugging Face account | Open the model page (the 🔗 next to it in ComfyUI, or let option 8 open it), sign in and click agree. Once per model |
| Option 8 says "Hugging Face refused access" or asks you to sign in | No token saved, or the token was deleted | ComfyNuke → **9 Sign in to Hugging Face** (see "Hugging Face token" above) |
| The download finished but ComfyUI still lists it as missing | ComfyUI has not re-read its model folders, or the file is still in Downloads | Press **R** in ComfyUI. If the file is in Downloads, start "Start ComfyUI" (the sorter moves it within seconds) or choose option 8 (it moves it too) |
| A red frame around a node and "not in list" in the black window | You pressed Run before that model finished downloading | Wait for the download, press **R**, then Run again |
| "Not enough free disk space" | Models are large | Free up space, or install ComfyNuke on a bigger drive |

**Do not rename downloaded model files.** Workflows and the sorter find models by their exact file name.

### The Downloads sorter

While "Start ComfyUI" is running, a small helper watches your Downloads folder and moves each finished model it recognises into the right `ComfyUI\models` subfolder. Files it does not recognise stay where they are; nothing is overwritten or deleted. Its log is `*-model-sorter.log` in the logs folder. The rules are below.

### How the sorter decides what to move

The sorter (`model_sorter.py`, started by "Start ComfyUI") decides **only by the exact file name**:

1. **Where names come from.** Every ComfyUI workflow lists the models it needs, each with its file name and its folder (for example `ltx-2.5-video-vae-bf16.safetensors` → `vae`). The sorter reads these lists from ComfyUI's built-in templates and from your saved workflows (`ComfyUI\user\*\workflows`). That is the same information ComfyUI shows under each name in "Missing Models". The list is refreshed every 5 minutes, so newly saved workflows are picked up.
2. **What it moves.** A file in Downloads whose name exactly matches a name on that list. A browser's duplicate name such as `model (1).safetensors` also counts as `model.safetensors`.
3. **When it moves.** Only finished downloads. While a browser is still downloading, the file has a temporary name (`.crdownload` in Chrome, `.part` in Firefox, `.download` in Safari), so it does not match. The size must also stay the same between two checks 5 seconds apart.
4. **Where it moves.** `ComfyUI\models\<folder>\<file name>`.
5. **What it never does.** It never moves a file it does not recognise, never overwrites an existing model and never deletes anything. If the same name belongs to more than one folder (for example `flux1-dev-fp8.safetensors` is used as both a checkpoint and a diffusion model), it leaves the file and asks you to move it by hand.

**Do not rename downloaded models.** A renamed file no longer matches, so it stays in Downloads, and the workflow will not find it either, because workflows also look models up by name. If that happens, rename it back or move it by hand to the folder shown in "Missing Models".

Cost: every 5 seconds it reads the list of file names in Downloads (under 1 ms); every 5 minutes it re-reads the workflow lists (about 0.3 s). It never reads file contents.

## Other Python on the same computer

ComfyNuke always runs its own Python by its full path and never looks up `python` on the PATH. Settings that could still leak in (`PYTHONHOME`, `PYTHONPATH`, `UV_*` and similar) are cleared, but only inside ComfyNuke and the "Start ComfyUI" window. Your system settings and any other Python you use stay exactly as they are. "Doctor" logs which of these settings were found.

## System requirements and version dependencies

Based on manifest `2026.10.19`. Update this section whenever `versions.json` changes.

| Item | Windows | Mac | Why |
|---|---|---|---|
| OS | Windows 10 1809 or later, 64-bit | macOS 14 or later | Windows: built-in `curl.exe` and `tar.exe`. Mac: the torch 2.14.1 wheel is `macosx_14_0_arm64` |
| CPU | x86-64 | Apple Silicon (M1 or later) | PyTorch no longer ships Intel Mac builds |
| Graphics | NVIDIA (see below); otherwise CPU, which is very slow | Apple GPU (MPS) | |
| Memory | 8 GB VRAM or more recommended | 16 GB unified memory or more recommended | SDXL, Flux and video models need a lot of memory |
| Disk | 25 GB plus models (usually 2–25 GB each) | Same | PyTorch plus the Python environment is about 5 GB |
| Nuke | 14 or later, full licence | Same | Nuke Non-commercial and Indie limit Python, so the plugin will most likely not work there |
| Python (for ComfyUI) | 3.12.13 | 3.12.13 | ComfyUI v0.42.1 has `requires-python = ">=3.10"` |
| Git | Private MinGit 2.56.0.2 | Apple Command Line Tools | |

**How Windows picks PyTorch** (top to bottom, first match wins):

| Build | PyTorch | Minimum NVIDIA driver | Graphics cards |
|---|---|---|---|
| cu130 | 2.14.1 | 580 | GTX 16 / RTX 20 series or newer (compute capability 7.5+) |
| cu128 | 2.11.0 | 570 | Same; mainly for RTX 50 series with a driver below 580 |
| cu126 | 2.14.1 | 528.33 | Older cards (GTX 10 series and similar); not RTX 50 series |
| cpu | 2.14.1 | — | No NVIDIA card |

**Before changing `versions.json`, check:**

- **ComfyUI's Python requirement:** `requires-python` in the new version's `pyproject.toml`. The script also checks this before an update and stops that item if it does not fit.
- **PyTorch wheels exist:** on Windows, `https://download.pytorch.org/whl/cu130/torch/` (same for cu126, cu128, cpu), look for `cp312-win_amd64`; on Mac, PyPI's torch files, where `macosx_XX_0_arm64` is the minimum macOS.
- **CUDA's minimum driver:** the driver table in NVIDIA's CUDA Toolkit Release Notes.
- **Nuke plugin compatibility:** "Compatibility changes" in each ComfyUI-for-Nuke release.
- **`nukeLibs`:** must support the Python of the oldest supported Nuke (Nuke 14 uses 3.9).

**Tested versions are a set.** If you pick ComfyUI or a node in "Check for updates" and the same tested set also has a newer Python, PyTorch or tool, those are added automatically. With `-Latest` (Windows) or `--latest` (Mac) you can pick untested upstream versions; then only the Python requirement is checked.

## Where things are

ComfyNuke sets **no environment variables and does not change PATH**. It only remembers the install folder, and every other path is worked out from it:

- Windows: `%LOCALAPPDATA%\ComfyNuke\config.json` holds `root` (for example `C:\ComfyNuke`).
- Mac: `~/Library/Application Support/ComfyNuke/config` holds `root=...`.

A copy of the tool lives in `<root>\app`. The Start menu shortcut and `<root>\ComfyNuke.bat` run that copy, and "Check for updates" updates it first. The private Git, uv and Python live in `<root>\tools` and are updated through "Check for updates" when a new tested version exists.

| Place (Windows) | Contents |
|---|---|
| `C:\ComfyNuke` (your choice) | ComfyUI, models, private tools, restore points, `history.log` |
| `%USERPROFILE%\.nuke\comfyui2nuke` | The Nuke plugin |
| `%USERPROFILE%\.nuke\comfynuke_libs` | `websocket-client` and other packages for Nuke's Python |
| `%USERPROFILE%\.nuke\menu.py` | One block marked `# >>> comfynuke >>>`; backed up before every change |
| `%LOCALAPPDATA%\ComfyNuke` | Logs and the install-folder setting |
| Desktop and Start menu | Shortcuts |

## Disk space and logs

- **Logs:** a few KB to a few hundred KB per run. Logs older than 90 days, or beyond the newest 200, are deleted automatically.
- **Restore points:** the newest 20 are kept; each is small (mostly a package list).
- **uv download cache** (`tools\uv-cache`): downloads no longer in use are cleared after every update or rollback.
- **Models** (`ComfyUI\models`) take most of the space and are never deleted automatically. "Doctor" shows how much space each part uses.

## Command line

```bash
powershell -ExecutionPolicy Bypass -File comfynuke.ps1 install -DryRun
```

Commands: `install`, `update`, `status`, `start`, `rollback`, `doctor`, `uninstall`, `self-update`. Windows options: `-Root`, `-Latest`, `-DryRun`, `-Yes`. Mac options: `--root`, `--latest`, `--dry-run`, `--yes`. A dry run only shows the plan and changes nothing.

## Maintaining

- To move to new tested versions: change versions and commits in `versions.json` → do a full install on a clean machine (or Windows Sandbox) → run a simple workflow in Nuke → bump `manifestVersion`, update `CHANGELOG.md` and the requirements above → tag (for example `v0.2.0`). GitHub Actions builds the release with `ComfyNuke.zip`.
- When `comfynuke.ps1` or `install.sh` changes, bump both `$AppVersion` and `APP_VERSION`. `self-update` compares them, and the release workflow fails if they differ.
- Save `comfynuke.ps1` as **UTF-8 with BOM**; Windows PowerShell 5.1 misreads non-ASCII characters otherwise.
- `install.sh` must work with macOS's bash 3.2 (no associative arrays, no `mapfile`). It reads `versions.json` with macOS's built-in `plutil`.

## Licence

ComfyNuke's own scripts are under the [MIT License](LICENSE). The software it installs keeps its own licences: ComfyUI and ComfyUI-for-Nuke (both GPL-3.0), the custom nodes (see their repositories), Nuke (a commercial Foundry licence) and each AI model (check its Hugging Face page; many do not allow commercial use).
