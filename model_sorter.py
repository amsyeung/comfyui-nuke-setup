"""Moves downloaded ComfyUI models from the Downloads folder into the right models/ subfolder.

When ComfyUI runs in a browser, its "Download" buttons save models to the browser's Downloads
folder instead of ComfyUI/models. This helper runs next to ComfyUI (started by "Start ComfyUI"),
watches Downloads and moves every finished model file it recognises.

It only moves files it is sure about: the file name must appear in a ComfyUI workflow
(the built-in templates or the user's saved workflows), which also says which folder it
belongs in. Anything else is left where it is. Nothing is ever deleted or overwritten.

Standard library only; runs with ComfyUI's own Python on Windows and macOS.
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

POLL_SECONDS = 5
INDEX_MAX_AGE = 300          # rebuild the name -> folder index every 5 minutes
DUPLICATE_SUFFIX = re.compile(r"^(.*?)(?: \(\d+\))(\.[^.]+)$")   # "model (1).safetensors" from repeated downloads


def downloads_dir():
    if sys.platform == "win32":
        try:
            import winreg
            key = winreg.OpenKey(winreg.HKEY_CURRENT_USER,
                                 r"Software\Microsoft\Windows\CurrentVersion\Explorer\User Shell Folders")
            value, _ = winreg.QueryValueEx(key, "{374DE290-123F-4565-9164-39C4925E467B}")
            return os.path.expandvars(value)
        except OSError:
            pass
    return os.path.join(os.path.expanduser("~"), "Downloads")


class Sorter:
    def __init__(self, comfy_dir, log_dir, downloads=None):
        self.comfy = comfy_dir
        self.models = os.path.join(comfy_dir, "models")
        self.downloads = downloads or downloads_dir()
        self.log_dir = log_dir
        self.index = {}
        self.index_time = 0.0
        self.sizes = {}          # file -> size at the previous poll (a file must be stable to be moved)
        self.reported = set()    # messages already shown, so each one appears once

    def log(self, message, once_key=None):
        if once_key is not None:
            if once_key in self.reported:
                return
            self.reported.add(once_key)
        line = f"[ComfyNuke] {message}"
        print(line, flush=True)
        if self.log_dir:
            try:
                os.makedirs(self.log_dir, exist_ok=True)
                name = datetime.date.today().strftime("%Y%m%d") + "-model-sorter.log"
                with open(os.path.join(self.log_dir, name), "a", encoding="utf-8") as f:
                    f.write(datetime.datetime.now().strftime("%H:%M:%S ") + message + "\n")
            except OSError:
                pass

    def workflow_files(self):
        site = [p for p in sys.path if p.endswith("site-packages")]
        for s in site:
            yield from glob.glob(os.path.join(s, "comfyui_workflow_templates*", "**", "*.json"), recursive=True)
        yield from glob.glob(os.path.join(self.comfy, "user", "*", "workflows", "**", "*.json"), recursive=True)

    def build_index(self):
        found = {}

        def walk(o):
            if isinstance(o, dict):
                name, folder = o.get("name"), o.get("directory")
                if isinstance(name, str) and isinstance(folder, str) and "." in name and "/" not in name and "\\" not in name:
                    found.setdefault(name, set()).add(folder.strip("/\\"))
                for v in o.values():
                    walk(v)
            elif isinstance(o, list):
                for v in o:
                    walk(v)

        for path in self.workflow_files():
            try:
                with open(path, encoding="utf-8") as f:
                    walk(json.load(f))
            except (OSError, ValueError):
                continue
        self.index = found
        self.index_time = time.time()

    def candidates(self):
        try:
            names = os.listdir(self.downloads)
        except OSError:
            return
        for name in names:
            path = os.path.join(self.downloads, name)
            if not os.path.isfile(path):
                continue
            model_name = name
            if name not in self.index:
                m = DUPLICATE_SUFFIX.match(name)
                if m and (m.group(1) + m.group(2)) in self.index:
                    model_name = m.group(1) + m.group(2)
                else:
                    continue
            yield path, model_name

    def poll(self):
        if time.time() - self.index_time > INDEX_MAX_AGE:
            self.build_index()
        seen = {}
        for path, model_name in self.candidates():
            try:
                size = os.path.getsize(path)
            except OSError:
                continue
            seen[path] = size
            if self.sizes.get(path) != size:
                continue   # still growing, or first time seen: wait one more poll
            self.place(path, model_name, size)
        self.sizes = seen

    def place(self, path, model_name, size):
        folders = sorted(self.index.get(model_name, ()))
        if len(folders) != 1:
            self.log(f"{model_name} is used in several model folders ({', '.join(folders)}); "
                     f"left in Downloads, please move it by hand.", once_key=("ambiguous", path))
            return
        target_dir = os.path.join(self.models, *folders[0].replace("\\", "/").split("/"))
        target = os.path.join(target_dir, model_name)
        if os.path.exists(target):
            if os.path.getsize(target) == size:
                self.log(f"{model_name} is already installed; the copy in Downloads is not needed.",
                         once_key=("dup", path))
            else:
                self.log(f"A different {model_name} is already installed; the download was left in Downloads.",
                         once_key=("diff", path))
            return
        try:
            os.makedirs(target_dir, exist_ok=True)
            shutil.move(path, target)   # a rename on the same drive, a copy across drives
        except OSError as e:
            self.log(f"Could not move {model_name} yet ({e}); will try again.", once_key=("err", path, str(e)))
            return
        rel = os.path.relpath(target_dir, self.comfy)
        self.log(f"Moved {model_name} ({size / 1024 ** 3:.1f} GB) to {rel}. In ComfyUI, press R to refresh the model list.")

    def run(self, once=False):
        self.build_index()
        self.log(f"Watching {self.downloads} for ComfyUI models ({len(self.index)} known names).")
        if once:
            self.poll()
            time.sleep(1)
            self.poll()
            return
        while True:
            self.poll()
            time.sleep(POLL_SECONDS)


def main():
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--comfy", required=True, help="ComfyUI folder")
    ap.add_argument("--log-dir", default="", help="folder for the daily log file")
    ap.add_argument("--once", action="store_true", help="check once and exit")
    ap.add_argument("--downloads", help="folder to watch (default: the browser's Downloads folder)")
    args = ap.parse_args()
    try:
        Sorter(os.path.abspath(args.comfy), args.log_dir, args.downloads).run(once=args.once)
    except KeyboardInterrupt:
        pass


if __name__ == "__main__":
    main()
