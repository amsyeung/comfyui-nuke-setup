"""Downloads the models a ComfyUI workflow needs, into the right ComfyUI/models folders.

Started from ComfyNuke ("Download missing models"). It is the reliable alternative to the
browser's Download buttons:
- Resumes: an interrupted download continues where it stopped the next time it runs.
- Fresh links: every attempt asks Hugging Face for a new download link, so links that
  expire during a long download are not a problem.
- Right folder: each model goes straight to the folder its workflow names (e.g. models/vae).
- Clear progress: one bar per file with size, speed and time left.

Runs with ComfyUI's own Python (it uses huggingface_hub, which ComfyUI already includes).
Never deletes or overwrites a model.
"""
import argparse
import datetime
import glob
import json
import os
import re
import shutil
import sys
import time
import urllib.error
import urllib.request

os.environ.setdefault("HF_HUB_DISABLE_TELEMETRY", "1")
# Classic HTTP downloads write to a partial file as they go, so a closed window or a shutdown
# can resume. Xet downloads were about as fast here but lost all progress when stopped.
os.environ["HF_HUB_DISABLE_XET"] = "1"

HF_URL = re.compile(r"^https://huggingface\.co/(?:(?P<type>datasets|spaces)/)?(?P<repo>[^/]+/[^/]+)/resolve/(?P<rev>[^/]+)/(?P<path>[^?#]+)")
# ComfyUI accepts these older folder names too
ALIASES = {"text_encoders": ["clip"], "diffusion_models": ["unet"], "clip": ["text_encoders"], "unet": ["diffusion_models"]}
STAGING = ".comfynuke-downloads"   # inside models/, so the final move is a quick rename on the same drive
RETRIES = 8


def say(msg=""):
    print(msg, flush=True)


class Log:
    def __init__(self, folder):
        self.path = None
        if folder:
            os.makedirs(folder, exist_ok=True)
            self.path = os.path.join(folder, datetime.date.today().strftime("%Y%m%d") + "-model-download.log")

    def __call__(self, msg):
        if self.path:
            with open(self.path, "a", encoding="utf-8") as f:
                f.write(datetime.datetime.now().strftime("%H:%M:%S ") + msg + "\n")


def gb(n):
    return f"{n / 1024 ** 3:.1f} GB" if n else "size unknown"


# ---- reading workflows ----------------------------------------------------------------

def models_in(workflow_path):
    """Every {name, url, directory} entry a workflow lists, unique by name."""
    found = {}

    def walk(o):
        if isinstance(o, dict):
            name, folder = o.get("name"), o.get("directory")
            if isinstance(name, str) and isinstance(folder, str) and "." in name:
                found.setdefault(name, {"name": name, "directory": folder.strip("/\\"), "url": o.get("url") or ""})
                if o.get("url") and not found[name]["url"]:
                    found[name]["url"] = o["url"]
            for v in o.values():
                walk(v)
        elif isinstance(o, list):
            for v in o:
                walk(v)

    try:
        with open(workflow_path, encoding="utf-8") as f:
            walk(json.load(f))
    except (OSError, ValueError):
        return []
    return list(found.values())


def installed(models_dir, model):
    for folder in [model["directory"]] + ALIASES.get(model["directory"], []):
        base = os.path.join(models_dir, *folder.split("/"))
        if os.path.isfile(os.path.join(base, model["name"])):
            return True
        if glob.glob(os.path.join(glob.escape(base), "**", glob.escape(model["name"])), recursive=True):
            return True
    return False


def templates_dir():
    for p in sys.path:
        d = os.path.join(p, "comfyui_workflow_templates_json", "templates")
        if os.path.isdir(d):
            return d
    return None


def template_catalogue():
    """(file, title, is_api) for every built-in template, from ComfyUI's English template index."""
    d = templates_dir()
    if not d:
        return []
    out = []
    try:
        with open(os.path.join(d, "index.json"), encoding="utf-8") as f:
            groups = json.load(f)
        for g in groups:
            for t in g.get("templates", []):
                path = os.path.join(d, t["name"] + ".json")
                if os.path.isfile(path):
                    tags = [x.lower() for x in t.get("tags", [])]
                    out.append((path, t.get("title") or t["name"], "api" in tags or t["name"].startswith("api_")))
    except (OSError, ValueError, KeyError):
        out = [(p, os.path.basename(p)[:-5], os.path.basename(p).startswith("api_"))
               for p in glob.glob(os.path.join(d, "*.json")) if not os.path.basename(p).startswith("index")]
    return out


def saved_workflows(comfy):
    files = glob.glob(os.path.join(comfy, "user", "*", "workflows", "**", "*.json"), recursive=True)
    return sorted(files, key=os.path.getmtime, reverse=True)


# ---- choosing a workflow ----------------------------------------------------------------

def ask(prompt):
    try:
        return input(prompt).strip().lstrip("﻿")
    except EOFError:
        return ""


def choose_workflow(comfy, models_dir):
    saved = []
    for path in saved_workflows(comfy):
        missing = [m for m in models_in(path) if not installed(models_dir, m)]
        if missing:
            saved.append((path, missing))
    say("Which workflow do you want the models for?")
    say("(Tip: in ComfyUI press Ctrl+S to save the workflow you have open, then it shows up here.)")
    say()
    for i, (path, missing) in enumerate(saved[:15], 1):
        age = datetime.datetime.fromtimestamp(os.path.getmtime(path)).strftime("%d %b %H:%M")
        say(f"  [{i}] {os.path.splitext(os.path.basename(path))[0]}  (saved {age}, {len(missing)} missing)")
    if not saved:
        say("  (no saved workflows with missing models)")
    say("  [S] Search ComfyUI's built-in templates by name")
    say("  [0] Cancel")
    while True:
        a = ask("Choose: ").lower()
        if a in ("", "0"):
            return None
        if a == "s":
            return search_templates(models_dir)
        if a.isdigit() and 1 <= int(a) <= len(saved[:15]):
            return saved[int(a) - 1][0]
        say("Please type one of the numbers, S or 0.")


def search_templates(models_dir):
    catalogue = template_catalogue()
    while True:
        q = ask("Words from the template's name (e.g. ltx 2.5 image to video), or Enter to cancel: ").lower()
        if not q:
            return None
        words = q.split()
        hits = [t for t in catalogue if all(w in (t[1] + " " + os.path.basename(t[0])).lower().replace("_", " ") for w in words)]
        if not hits:
            say("No template matches. Try fewer or different words.")
            continue
        for i, (path, title, api) in enumerate(hits[:15], 1):
            missing = sum(1 for m in models_in(path) if not installed(models_dir, m))
            note = "cloud API, paid, no downloads" if api else (f"{missing} missing" if missing else "all models installed")
            say(f"  [{i}] {title}  ({note})")
        a = ask("Choose a number (or Enter to search again): ")
        if a.isdigit() and 1 <= int(a) <= len(hits[:15]):
            return hits[int(a) - 1][0]


# ---- downloading ------------------------------------------------------------------------

def hf_parts(url):
    m = HF_URL.match(url or "")
    if not m:
        return None
    return {"repo_id": m["repo"], "repo_type": {"datasets": "dataset", "spaces": "space"}.get(m["type"], "model"),
            "revision": m["rev"], "filename": urllib.request.unquote(m["path"])}


def hf_size(parts):
    """File size, or raises if Hugging Face refuses access (not signed in / licence not accepted)."""
    from huggingface_hub import get_hf_file_metadata, hf_hub_url
    url = hf_hub_url(parts["repo_id"], parts["filename"], repo_type=parts["repo_type"], revision=parts["revision"])
    return get_hf_file_metadata(url).size or 0


def explain_hf_error(e, parts):
    from huggingface_hub.errors import GatedRepoError, RepositoryNotFoundError, EntryNotFoundError
    page = f"https://huggingface.co/{parts['repo_id']}"
    if isinstance(e, GatedRepoError):
        return f"needs its licence accepted: open {page}, sign in and accept the terms, then try again."
    if isinstance(e, RepositoryNotFoundError):
        return "Hugging Face refused access. Sign in (option in this menu) and check the model page: " + page
    if isinstance(e, EntryNotFoundError):
        return "the file is no longer on Hugging Face; the workflow may need an update."
    return f"{type(e).__name__}: {e}"


def licence_page(e, parts):
    """The page the user must visit to fix this, or None when it is not something they can fix there."""
    from huggingface_hub.errors import GatedRepoError, RepositoryNotFoundError
    if parts and isinstance(e, (GatedRepoError, RepositoryNotFoundError)):
        return f"https://huggingface.co/{parts['repo_id']}"
    return None


def report_pending(pending, yes, log):
    """Repeat, at the very end, what the user still has to do (it scrolls away behind progress bars)."""
    if not pending:
        return
    say()
    say("Needs your action:")
    for name, reason, _ in pending:
        say(f"  ! {name}: {reason}")
        log(f"skipped {name}: {reason}")
    pages = sorted({page for _, _, page in pending if page})
    if pages:
        say()
        say("Each model page has an agree button for its licence. This is done once per model, by you, while signed in to")
        say("Hugging Face in your browser. Then choose \"Download missing models\" again to get the skipped files.")
        if not yes and ask(f"Open {'this page' if len(pages) == 1 else 'these pages'} in your browser now? [Y/n] ").lower() in ("", "y", "yes"):
            import webbrowser
            for page in pages:
                webbrowser.open(page)


def download_hf(parts, staging):
    from huggingface_hub import hf_hub_download
    return hf_hub_download(parts["repo_id"], parts["filename"], repo_type=parts["repo_type"],
                           revision=parts["revision"], local_dir=staging)


def download_http(url, dest):
    """Plain HTTP with resume (for models hosted outside Hugging Face)."""
    from tqdm import tqdm
    part = dest + ".part"
    pos = os.path.getsize(part) if os.path.exists(part) else 0
    headers = {"User-Agent": "ComfyNuke"}
    if pos:
        headers["Range"] = f"bytes={pos}-"
    with urllib.request.urlopen(urllib.request.Request(url, headers=headers), timeout=60) as r:
        if pos and r.status != 206:
            pos = 0   # server cannot resume: start again
        total = pos + int(r.headers.get("Content-Length") or 0)
        with open(part, "ab" if pos else "wb") as f, tqdm(total=total or None, initial=pos, unit="B", unit_scale=True,
                                                         unit_divisor=1024, desc=os.path.basename(dest)) as bar:
            while True:
                chunk = r.read(1 << 20)
                if not chunk:
                    break
                f.write(chunk)
                bar.update(len(chunk))
    os.replace(part, dest)
    return dest


def fetch(model, models_dir, log, pending):
    target_dir = os.path.join(models_dir, *model["directory"].split("/"))
    target = os.path.join(target_dir, model["name"])
    os.makedirs(target_dir, exist_ok=True)
    parts = hf_parts(model["url"])
    for attempt in range(1, RETRIES + 1):
        try:
            if parts:
                staging = os.path.join(models_dir, STAGING, parts["repo_id"].replace("/", "__"))
                got = download_hf(parts, staging)
                if os.path.exists(target):
                    say(f"  {model['name']} appeared in the meantime; leaving the existing file.")
                else:
                    shutil.move(got, target)
            else:
                download_http(model["url"], target)
            log(f"downloaded {model['name']} -> {model['directory']}")
            return True
        except KeyboardInterrupt:
            raise
        except Exception as e:  # network trouble: wait and resume with a fresh link
            from huggingface_hub.errors import GatedRepoError, RepositoryNotFoundError, EntryNotFoundError
            if parts and isinstance(e, (GatedRepoError, RepositoryNotFoundError, EntryNotFoundError)):
                say(f"  Cannot download {model['name']}: {explain_hf_error(e, parts)}")
                pending.append((model["name"], explain_hf_error(e, parts), licence_page(e, parts)))
                return False
            wait = min(60, 5 * attempt)
            say(f"  Connection problem ({type(e).__name__}). Resuming in {wait} s (try {attempt} of {RETRIES})...")
            log(f"retry {attempt} {model['name']}: {type(e).__name__}: {e}")
            time.sleep(wait)
    say(f"  Gave up on {model['name']} for now. Run this again later: it continues where it stopped.")
    return False


def from_downloads(model, models_dir):
    """If the browser already finished this file, move it instead of downloading again."""
    try:
        sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
        from model_sorter import downloads_dir
        src = os.path.join(downloads_dir(), model["name"])
    except Exception:
        return False
    if not os.path.isfile(src):
        return False
    target_dir = os.path.join(models_dir, *model["directory"].split("/"))
    os.makedirs(target_dir, exist_ok=True)
    shutil.move(src, os.path.join(target_dir, model["name"]))
    say(f"  Found {model['name']} in Downloads and moved it to models/{model['directory']}.")
    return True


def ensure_signed_in(need):
    if not need:
        return True
    from huggingface_hub import get_token, login
    if get_token():
        return True
    say()
    say("Some of these models are on Hugging Face and need you to be signed in.")
    say("1. Open https://huggingface.co/settings/tokens and create a token (type: Read).")
    say("2. Paste it below. It is saved on this computer only; nothing is shown while you paste.")
    try:
        login(add_to_git_credential=False)
    except Exception as e:
        say(f"Sign-in failed: {e}")
        return False
    return bool(get_token())


def run(comfy, workflow, log_dir, yes):
    log = Log(log_dir)
    models_dir = os.path.join(comfy, "models")
    say()
    say("=== Download missing models ===")
    if not workflow:
        workflow = choose_workflow(comfy, models_dir)
        if not workflow:
            say("Nothing chosen.")
            return 0
    wanted = models_in(workflow)
    missing = [m for m in wanted if not installed(models_dir, m)]
    say()
    say(f"Workflow: {os.path.splitext(os.path.basename(workflow))[0]}")
    if not wanted:
        say("This workflow does not list any downloadable models (it may use a cloud API or need models added by hand).")
        return 0
    if not missing:
        say(f"All {len(wanted)} models are already installed. Nothing to do.")
        return 0
    no_url = [m for m in missing if not m["url"]]
    missing = [m for m in missing if m["url"]]
    for m in no_url:
        say(f"  ! {m['name']} has no download link in the workflow; it has to be added by hand to models/{m['directory']}.")
    if not missing:
        return 1
    missing = [m for m in missing if not from_downloads(m, models_dir)]
    if not missing:
        say("Done: everything was already in Downloads and has been moved.")
        return 0
    if not ensure_signed_in(any(hf_parts(m["url"]) for m in missing)):
        return 1

    say()
    say("Checking the files...")
    total = 0
    pending = []   # (model, reason, page to fix it): shown again at the end and written to the log
    for m in missing:
        parts = hf_parts(m["url"])
        m["size"] = 0
        if parts:
            try:
                m["size"] = hf_size(parts)
            except Exception as e:
                reason = explain_hf_error(e, parts)
                say(f"  ! {m['name']}: {reason}")
                pending.append((m["name"], reason, licence_page(e, parts)))
                m["skip"] = True
        total += m["size"]
    todo = [m for m in missing if not m.get("skip")]
    if not todo:
        report_pending(pending, yes, log)
        return 1
    free = shutil.disk_usage(models_dir).free
    say()
    say(f"To download ({len(todo)} file{'' if len(todo) == 1 else 's'}, {gb(total)}; {gb(free)} free on this drive):")
    for m in todo:
        say(f"  - {m['name']}  {gb(m['size'])}  -> models/{m['directory']}")
    if total and free < total * 1.05:
        say("Not enough free disk space. Free up space or move ComfyNuke to a bigger drive first.")
        return 1
    if not yes and ask("Start? [Y/n] ").lower() not in ("", "y", "yes"):
        report_pending(pending, yes, log)
        return 0

    log(f"workflow {os.path.basename(workflow)}: {len(todo)} files, {total} bytes")
    ok = 0
    try:
        for i, m in enumerate(todo, 1):
            say()
            say(f"[{i}/{len(todo)}] {m['name']}  ({gb(m['size'])})  -> models/{m['directory']}")
            ok += fetch(m, models_dir, log, pending)
    except KeyboardInterrupt:
        say()
        say("Paused. Choose \"Download missing models\" again to continue where it stopped.")
        log("paused by user")
        report_pending(pending, yes, log)
        return 1
    finally:
        # Partial downloads stay in the staging folder so the next run can resume them
        for root, dirs, files in os.walk(os.path.join(models_dir, STAGING), topdown=False):
            if not dirs and not files:
                try:
                    os.rmdir(root)
                except OSError:
                    pass
    say()
    if ok == len(todo):
        # nothing left to resume: clear the staging folder (only our own temporary files live there)
        shutil.rmtree(os.path.join(models_dir, STAGING), ignore_errors=True)
        say(f"Done: {ok} of {len(todo)} downloaded. If ComfyUI is open, press R there to refresh the model list.")
    else:
        say(f"{ok} of {len(todo)} downloaded. Run this again later to continue; finished files are kept.")
    report_pending(pending, yes, log)
    return 0 if ok == len(todo) and not pending else 1


def main():
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--comfy", required=True, help="ComfyUI folder")
    ap.add_argument("--workflow", help="workflow .json file (default: ask)")
    ap.add_argument("--log-dir", default="", help="folder for the daily log file")
    ap.add_argument("--yes", action="store_true", help="do not ask before downloading")
    args = ap.parse_args()
    sys.exit(run(os.path.abspath(args.comfy), args.workflow, args.log_dir, args.yes))


if __name__ == "__main__":
    main()
