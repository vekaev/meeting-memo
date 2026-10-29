# /// script
# requires-python = ">=3.10"
# dependencies = ["mlx-whisper>=0.4"]
# ///
"""Transcribe one Meeting Memo recording on this Mac and write a Markdown note next to it.

Usage: uv run --script transcribe.py <audio> <note.md> [--title T] [--meeting M] [--recorded R]
                                     [--minutes N] [--language xx] [--model hf/repo]

afconvert (built into macOS) decodes the audio to 16 kHz mono; Whisper large-v3-turbo runs through
MLX on Apple Silicon. Nothing is uploaded: Meeting Memo sets HF_HUB_OFFLINE=1 once the model is in
the Hugging Face cache, so not even a model check goes out. The note is written to a temp file and
renamed, so a half-written transcript never appears.
"""
from __future__ import annotations

import argparse
import pathlib
import subprocess
import sys
import tempfile
import wave

DEFAULT_MODEL = "mlx-community/whisper-large-v3-turbo"


def load_audio(path: pathlib.Path):
    import numpy as np

    with tempfile.TemporaryDirectory() as tmp:
        wav = pathlib.Path(tmp) / "audio.wav"
        subprocess.run(["/usr/bin/afconvert", "-f", "WAVE", "-d", "LEI16@16000", "-c", "1", str(path), str(wav)],
                       check=True, capture_output=True)
        with wave.open(str(wav)) as file:
            frames = file.readframes(file.getnframes())
    return np.frombuffer(frames, dtype=np.int16).astype(np.float32) / 32768.0


def clock(seconds: float) -> str:
    seconds = int(seconds)
    return f"{seconds // 3600}:{seconds // 60 % 60:02d}:{seconds % 60:02d}" if seconds >= 3600 \
        else f"{seconds // 60:02d}:{seconds % 60:02d}"


def lines(segments):
    """One line per segment, dropping Whisper's repeats over silence."""
    previous = None
    for segment in segments:
        text = segment["text"].strip()
        if not text or text == previous:
            continue
        previous = text
        yield f"[{clock(segment['start'])}] {text}"


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("audio", type=pathlib.Path)
    parser.add_argument("note", type=pathlib.Path)
    parser.add_argument("--title")
    parser.add_argument("--meeting")
    parser.add_argument("--recorded")
    parser.add_argument("--minutes")
    parser.add_argument("--language")
    parser.add_argument("--model", default=DEFAULT_MODEL)
    args = parser.parse_args()

    import mlx_whisper

    audio = load_audio(args.audio)
    result = mlx_whisper.transcribe(audio, path_or_hf_repo=args.model, language=args.language,
                                    condition_on_previous_text=False)
    body = "\n".join(lines(result.get("segments", []))) or "_No speech found._"

    header = [f"# {args.title or args.audio.stem}", ""]
    for label, value in [("Meeting", args.meeting), ("Recorded", args.recorded), ("Length", args.minutes),
                         ("Language", result.get("language")), ("Audio", args.audio.name)]:
        if value:
            header.append(f"- {label}: {value}")
    note = "\n".join(header) + "\n\n## Transcript\n\n" + body + "\n"

    temp = args.note.with_name("." + args.note.name + ".partial")
    temp.write_text(note, encoding="utf-8")
    temp.replace(args.note)
    print(args.note)


if __name__ == "__main__":
    try:
        main()
    except Exception as error:
        print(f"transcribe failed: {error}", file=sys.stderr)
        sys.exit(1)
