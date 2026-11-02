# SPDX-License-Identifier: MPL-2.0
"""TrackSplit separation engine.

The Swift app runs this script and reads one JSON object per line from its
standard output. Two commands:

  setup     Run with any Python 3.10-3.13. Builds the private runtime under
            --data (a venv with audio-separator, PyTorch and a static FFmpeg)
            and downloads the htdemucs_ft model. Safe to run again.
  separate  Run with the runtime's own Python. Separates one track into
            vocals, drums and bass and publishes the three containers the
            RX3 deck mod reads into --stems-dir, then updates the manifest.

The container format and the alignment to the deck's decoder grid come from
rx3-toolkit (commit 7d243f8) through the vendored `rx3_stem` module.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import pathlib
import re
import shutil
import signal
import subprocess
import sys
import tempfile
import time

MODEL = "htdemucs_ft.yaml"
# Demucs leaves the mix alone; 1.0 only keeps a stem above full scale from
# being rescaled, which is what the toolkit pins for the deck's subtraction.
SEPARATOR_FLAGS = ("--normalization=1.0",)
ROLE_STEMS = {"vocals": "Vocals", "drums": "Drums", "bass": "Bass"}
ROLE_ORDER = ("vocals", "drums", "bass")
ROLE_SUFFIXES = {"vocals": ".rx3stem", "drums": ".rx3drums", "bass": ".rx3bass"}
MANIFEST_NAME = "rx3-stems-manifest.json"
PARTIAL_SUFFIX = ".partial"
PACKAGES = ("audio-separator[cpu]", "librosa<1.0", "imageio-ffmpeg")
PERCENT = re.compile(r"(\d{1,3})%")
READY_NAME = "ready.json"
RUNTIME_VERSION = 1

_child: subprocess.Popen | None = None


def emit(event: str, **values: object) -> None:
    print(json.dumps({"event": event, **values}, ensure_ascii=False), flush=True)


def _terminate(signum, frame):  # noqa: ARG001
    if _child is not None and _child.poll() is None:
        _child.terminate()
        try:
            _child.wait(timeout=5)
        except subprocess.TimeoutExpired:
            _child.kill()
    # Unwinds through the temporary directories so nothing is left behind.
    raise KeyboardInterrupt


def run_streaming(command: list[str], env: dict[str, str] | None, on_percent=None) -> tuple[int, str]:
    """Run a command, report tqdm percentages, and keep the tail of its output."""
    global _child
    _child = subprocess.Popen(
        command, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
        text=True, bufsize=1, env=env, errors="replace",
    )
    assert _child.stdout is not None
    window = ""
    transcript = ""
    last = -1
    # tqdm writes carriage returns, so read characters rather than lines.
    while True:
        character = _child.stdout.read(1)
        if not character:
            break
        window = (window + character)[-96:]
        transcript = (transcript + character)[-16384:]
        if on_percent and character == "%":
            # The newest figure is the one just completed by this "%".
            found = PERCENT.findall(window)
            if found:
                value = min(int(found[-1]), 100)
                if value != last:
                    on_percent(value)
                    last = value
    code = _child.wait()
    _child = None
    return code, transcript


def failure_detail(transcript: str) -> str:
    lines = [
        line.strip() for line in transcript.replace("\r", "\n").splitlines()
        if line.strip() and "%|" not in line
    ]
    return " / ".join(lines[-6:])[-600:] if lines else "sem saída"


# ---------------------------------------------------------------- runtime ---

def runtime_paths(data: pathlib.Path) -> dict[str, pathlib.Path]:
    venv = data / "runtime"
    return {
        "venv": venv,
        "python": venv / "bin" / "python3",
        "separator": venv / "bin" / "audio-separator",
        "models": data / "models",
        "bin": data / "bin",
        "ffmpeg": data / "bin" / "ffmpeg",
        "ready": data / READY_NAME,
    }


def bundled_ffmpeg(venv: pathlib.Path) -> pathlib.Path | None:
    for root in sorted(venv.glob("lib/python3.*/site-packages")):
        for candidate in sorted((root / "imageio_ffmpeg/binaries").glob("ffmpeg-*")):
            if candidate.is_file() and os.access(candidate, os.X_OK):
                return candidate
    return None


def environment(paths: dict[str, pathlib.Path]) -> dict[str, str]:
    values = os.environ.copy()
    values["AUDIO_SEPARATOR_MODEL_DIR"] = str(paths["models"])
    values["TORCH_HOME"] = str(paths["models"])
    values["PATH"] = os.pathsep.join([str(paths["bin"]), str(paths["venv"] / "bin"), values.get("PATH", "")])
    values["PYTHONUNBUFFERED"] = "1"
    return values


def command_setup(args: argparse.Namespace) -> int:
    data = pathlib.Path(args.data)
    paths = runtime_paths(data)
    data.mkdir(parents=True, exist_ok=True)
    paths["ready"].unlink(missing_ok=True)
    steps = 5

    def step(index: int, label: str) -> None:
        emit("setup", step=index, steps=steps, label=label)

    if not paths["python"].is_file():
        step(1, "Criando ambiente Python")
        shutil.rmtree(paths["venv"], ignore_errors=True)
        code, out = run_streaming([sys.executable, "-m", "venv", str(paths["venv"])], None)
        if code:
            emit("error", message=f"Não foi possível criar o ambiente Python: {failure_detail(out)}")
            return 1
    python = str(paths["python"])
    step(2, "Atualizando pip")
    run_streaming([python, "-m", "pip", "install", "--upgrade", "pip"], None)
    step(3, "Instalando audio-separator, PyTorch e FFmpeg (≈1,5 GB)")
    code, out = run_streaming(
        [python, "-m", "pip", "install", "--progress-bar", "off", *PACKAGES], None,
    )
    if code or not paths["separator"].is_file():
        emit("error", message=f"Falha ao instalar o audio-separator: {failure_detail(out)}")
        return 1
    ffmpeg = bundled_ffmpeg(paths["venv"])
    if ffmpeg is None:
        emit("error", message="O FFmpeg do imageio-ffmpeg não foi encontrado.")
        return 1
    paths["bin"].mkdir(parents=True, exist_ok=True)
    paths["ffmpeg"].unlink(missing_ok=True)
    paths["ffmpeg"].symlink_to(ffmpeg)
    step(4, "Baixando o modelo htdemucs_ft (≈330 MB)")
    paths["models"].mkdir(parents=True, exist_ok=True)
    code, out = run_streaming(
        [str(paths["separator"]), "--download_model_only", f"--model_filename={MODEL}",
         f"--model_file_dir={paths['models']}"],
        environment(paths),
        on_percent=lambda value: emit("setup", step=4, steps=steps,
                                      label="Baixando o modelo htdemucs_ft (≈330 MB)", percent=value),
    )
    if code:
        emit("error", message=f"Falha ao baixar o modelo: {failure_detail(out)}")
        return 1
    step(5, "Verificando")
    code, out = run_streaming([python, "-c", "import torch; print('mps', torch.backends.mps.is_available())"], None)
    paths["ready"].write_text(json.dumps({
        "version": RUNTIME_VERSION, "model": MODEL,
        "metal": "mps True" in out, "ffmpeg": str(ffmpeg),
        "createdAt": time.strftime("%Y-%m-%dT%H:%M:%S%z"),
    }, indent=2))
    emit("ready", metal="mps True" in out)
    return 0


# ------------------------------------------------------------- separation ---

def sha256(path: pathlib.Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        while chunk := handle.read(1024 * 1024):
            digest.update(chunk)
    return digest.hexdigest()


def publish(local: pathlib.Path, target: pathlib.Path) -> None:
    """Copy onto the drive under a partial name, then rename into place."""
    partial = target.with_name(target.name + PARTIAL_SUFFIX)
    try:
        with local.open("rb") as source, partial.open("wb") as destination:
            shutil.copyfileobj(source, destination, 1024 * 1024)
            destination.flush()
            os.fsync(destination.fileno())
        os.replace(partial, target)
    finally:
        partial.unlink(missing_ok=True)
        drop_appledouble(target)


def drop_appledouble(target: pathlib.Path) -> None:
    """Remove the `._name` file macOS writes beside a file on FAT/exFAT.

    It only carries `com.apple.provenance`, which the system attaches to
    whatever this app writes and will not let anyone strip; on the drive it
    would just be clutter next to every stem.
    """
    for name in (target.name, target.name + PARTIAL_SUFFIX):
        (target.parent / f"._{name}").unlink(missing_ok=True)


def update_manifest(stems_dir: pathlib.Path, entry: dict) -> None:
    manifest = stems_dir / MANIFEST_NAME
    entries: list = []
    try:
        loaded = json.loads(manifest.read_text(encoding="utf-8"))
        entries = [item for item in loaded.get("tracks", []) if isinstance(item, dict)]
    except (OSError, ValueError, AttributeError):
        entries = []
    entries = [item for item in entries if item.get("stem") != entry["stem"]]
    entries.append(entry)
    contents = json.dumps({"format": 2, "createdAt": time.strftime("%Y-%m-%dT%H:%M:%S%z"),
                           "tracks": entries}, ensure_ascii=False, indent=2) + "\n"
    with tempfile.TemporaryDirectory(prefix="tracksplit-manifest-") as directory:
        local = pathlib.Path(directory) / MANIFEST_NAME
        local.write_text(contents, encoding="utf-8")
        publish(local, manifest)


def command_separate(args: argparse.Namespace) -> int:
    sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent))
    from rx3_stem import write_stem  # noqa: E402

    paths = runtime_paths(pathlib.Path(args.data))
    source = pathlib.Path(args.source)
    stems_dir = pathlib.Path(args.stems_dir)
    # The deck asks for exactly the basename it loaded, up to the last dot,
    # spaces and all; the Swift side passes it through untouched.
    base = args.base
    if not source.is_file():
        emit("error", message="Arquivo de música não encontrado no pendrive.")
        return 1
    if not base or "/" in base:
        emit("error", message=f"Nome de stem inválido: {base!r}")
        return 1
    stems_dir.mkdir(parents=True, exist_ok=True)
    targets = {role: stems_dir / f"{base}{ROLE_SUFFIXES[role]}" for role in ROLE_ORDER}
    started = time.monotonic()

    with tempfile.TemporaryDirectory(prefix="tracksplit-") as directory:
        workspace = pathlib.Path(directory)
        # Work from a local copy: the separator and three FFmpeg passes all
        # read the source, and a USB stick is the slowest place to do that.
        emit("stage", stage="copying", percent=0)
        local_source = workspace / ("source" + source.suffix)
        shutil.copyfile(source, local_source)
        source_sha = sha256(local_source)
        separated_dir = workspace / "separated"
        separated_dir.mkdir()

        emit("stage", stage="separating", percent=1)
        command = [
            str(paths["separator"]), str(local_source),
            f"--model_file_dir={paths['models']}",
            f"--output_dir={separated_dir}",
            "--output_format=WAV",
            f"--model_filename={MODEL}",
            *SEPARATOR_FLAGS,
        ]
        code, transcript = run_streaming(
            command, environment(paths),
            on_percent=lambda value: emit("stage", stage="separating", percent=value),
        )
        if code:
            emit("error", message=f"audio-separator saiu com código {code}: {failure_detail(transcript)}")
            return 1
        candidates = sorted(separated_dir.rglob("*.wav"))
        separated: dict[str, pathlib.Path] = {}
        for role in ROLE_ORDER:
            marker = f"({ROLE_STEMS[role]})".casefold()
            matches = [item for item in candidates if marker in item.name.casefold()]
            if len(matches) != 1:
                emit("error", message=f"Esperava um stem {ROLE_STEMS[role]}, encontrei {len(matches)}: "
                                      f"{failure_detail(transcript)}")
                return 1
            separated[role] = matches[0]

        encoded = {}
        for position, role in enumerate(ROLE_ORDER):
            emit("stage", stage="encoding", role=role, percent=position * 100 // len(ROLE_ORDER))
            local = workspace / targets[role].name
            encoded[role] = write_stem(
                separated[role], local, ffmpeg=str(paths["ffmpeg"]), sample_format="s16",
                match_full=local_source, separator_normalization=None,
            )

        needed = sum(result.output.stat().st_size for result in encoded.values())
        if shutil.disk_usage(stems_dir).free < needed + 8 * 1024 * 1024:
            emit("error", message="Sem espaço livre no pendrive para este track.")
            return 1
        emit("stage", stage="writing", percent=0)
        for position, role in enumerate(ROLE_ORDER):
            publish(encoded[role].output, targets[role])
            emit("stage", stage="writing", percent=(position + 1) * 100 // len(ROLE_ORDER))

        first = encoded["vocals"]
        entry = {
            "trackId": args.track_id, "artist": args.artist, "title": args.title,
            "sourceFile": source.name, "stem": targets["vocals"].name,
            "bytes": targets["vocals"].stat().st_size, "status": "created",
            "gainCorrection": round(first.gain, 6),
            "clippedSamples": sum(result.clipped for result in encoded.values()),
            "encoderDelayFrames": first.delay,
            "source_sha256": source_sha, "source_bytes": source.stat().st_size,
            "processing": {"model": MODEL, "roles": list(ROLE_ORDER), "tool": "TrackSplit"},
            "stems": [
                {"role": role, "file": targets[role].name, "bytes": targets[role].stat().st_size,
                 "clippedSamples": encoded[role].clipped, "sha256": sha256(encoded[role].output)}
                for role in ROLE_ORDER
            ],
        }
        update_manifest(stems_dir, entry)

    emit("done", seconds=round(time.monotonic() - started, 1),
         files=[targets[role].name for role in ROLE_ORDER],
         aligned=all(result.aligned for result in encoded.values()))
    return 0


def main() -> int:
    parser = argparse.ArgumentParser(prog="tracksplit_engine")
    commands = parser.add_subparsers(dest="command", required=True)
    setup = commands.add_parser("setup")
    setup.add_argument("--data", required=True)
    separate = commands.add_parser("separate")
    separate.add_argument("--data", required=True)
    separate.add_argument("--source", required=True)
    separate.add_argument("--stems-dir", required=True)
    separate.add_argument("--base", required=True)
    separate.add_argument("--track-id", default="")
    separate.add_argument("--title", default="")
    separate.add_argument("--artist", default="")
    args = parser.parse_args()
    signal.signal(signal.SIGTERM, _terminate)
    signal.signal(signal.SIGINT, _terminate)
    try:
        return command_setup(args) if args.command == "setup" else command_separate(args)
    except KeyboardInterrupt:
        emit("cancelled")
        return 130
    except Exception as error:  # reported to the app rather than lost
        emit("error", message=f"{type(error).__name__}: {error}")
        return 1


if __name__ == "__main__":
    sys.exit(main())
