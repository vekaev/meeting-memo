# /// script
# requires-python = ">=3.10"
# dependencies = ["mlx-whisper>=0.4", "sherpa-onnx>=1.10"]
# ///
"""Transcribe one Meeting Memo recording on this Mac, with who spoke when, and write a Markdown note.

Usage: uv run --script transcribe.py <audio> <note.md> [--title T] [--meeting M] [--recorded R]
                                     [--minutes N] [--language xx] [--model hf/repo] [--speakers N]
                                     [--no-speakers]

afconvert (built into macOS) decodes the audio to 16 kHz mono; Whisper large-v3-turbo runs through
MLX on Apple Silicon with word timestamps. sherpa-onnx tells the voices apart (pyannote segmentation
plus a WeSpeaker embedding, both small ONNX models fetched once from the sherpa-onnx GitHub releases
into ~/Library/Application Support/MeetingMemo/models), and each word goes to the voice speaking at
that moment. Nothing about the recording is uploaded: Meeting Memo sets HF_HUB_OFFLINE=1 once the
Whisper model is cached. The note is written to a temp file and renamed, so a half-written transcript
never appears.
"""
from __future__ import annotations

import argparse
import pathlib
import subprocess
import sys
import tarfile
import tempfile
import urllib.request
import wave

DEFAULT_MODEL = "mlx-community/whisper-large-v3-turbo"
MODELS = pathlib.Path.home() / "Library/Application Support/MeetingMemo/models"
RELEASES = "https://github.com/k2-fsa/sherpa-onnx/releases/download"
SEGMENTATION = MODELS / "sherpa-onnx-pyannote-segmentation-3-0/model.onnx"
EMBEDDING = MODELS / "wespeaker_en_voxceleb_resnet34_LM.onnx"
SAMPLE_RATE = 16000
# A pause this long, or a change of speaker, starts a new paragraph
PARAGRAPH_GAP = 2.0


def log(message):
    print(message, file=sys.stderr, flush=True)


def load_audio(path: pathlib.Path):
    import numpy as np

    with tempfile.TemporaryDirectory() as tmp:
        wav = pathlib.Path(tmp) / "audio.wav"
        subprocess.run(["/usr/bin/afconvert", "-f", "WAVE", "-d", f"LEI16@{SAMPLE_RATE}", "-c", "1", str(path), str(wav)],
                       check=True, capture_output=True)
        with wave.open(str(wav)) as file:
            frames = file.readframes(file.getnframes())
    return np.frombuffer(frames, dtype=np.int16).astype(np.float32) / 32768.0


def clock(seconds: float) -> str:
    seconds = int(seconds)
    return f"{seconds // 3600}:{seconds // 60 % 60:02d}:{seconds % 60:02d}" if seconds >= 3600 \
        else f"{seconds // 60:02d}:{seconds % 60:02d}"


def ensure_models():
    """Fetch the two diarization models once (they hold no data about the recording)."""
    if not SEGMENTATION.exists():
        log("Downloading the speaker segmentation model (6 MB, once)")
        MODELS.mkdir(parents=True, exist_ok=True)
        archive = MODELS / "segmentation.tar.bz2"
        urllib.request.urlretrieve(f"{RELEASES}/speaker-segmentation-models/sherpa-onnx-pyannote-segmentation-3-0.tar.bz2", archive)
        with tarfile.open(archive) as tar:
            tar.extractall(MODELS, filter="data")
        archive.unlink()
    if not EMBEDDING.exists():
        log("Downloading the speaker embedding model (26 MB, once)")
        partial = EMBEDDING.with_suffix(".partial")
        urllib.request.urlretrieve(f"{RELEASES}/speaker-recongition-models/{EMBEDDING.name}", partial)
        partial.replace(EMBEDDING)


def diarize(audio, speakers: int | None):
    """[(start, end, speaker)] sorted by start; speakers numbered by first appearance."""
    import sherpa_onnx

    ensure_models()
    config = sherpa_onnx.OfflineSpeakerDiarizationConfig(
        segmentation=sherpa_onnx.OfflineSpeakerSegmentationModelConfig(
            pyannote=sherpa_onnx.OfflineSpeakerSegmentationPyannoteModelConfig(model=str(SEGMENTATION))),
        embedding=sherpa_onnx.SpeakerEmbeddingExtractorConfig(model=str(EMBEDDING)),
        clustering=sherpa_onnx.FastClusteringConfig(num_clusters=speakers or -1, threshold=0.5),
        min_duration_on=0.3,
        min_duration_off=0.5,
    )
    result = sherpa_onnx.OfflineSpeakerDiarization(config).process(audio).sort_by_start_time()
    order: dict[int, int] = {}
    turns = []
    for segment in result:
        number = order.setdefault(segment.speaker, len(order) + 1)
        turns.append((segment.start, segment.end, number))
    return turns


def speaker_at(turns, start: float, end: float):
    """The speaker who talks most during [start, end]; the nearest one if nobody does."""
    best, overlap = None, 0.0
    for turn_start, turn_end, speaker in turns:
        if turn_start > end:
            break
        shared = min(end, turn_end) - max(start, turn_start)
        if shared > overlap:
            best, overlap = speaker, shared
    if best is None and turns:
        middle = (start + end) / 2
        best = min(turns, key=lambda t: min(abs(t[0] - middle), abs(t[1] - middle)))[2]
    return best


def paragraphs(segments, turns):
    """[(speaker, start, text)]: words grouped by speaker, split at long pauses; Whisper's repeats dropped."""
    words, previous = [], None
    for segment in segments:
        text = segment["text"].strip()
        if not text or text == previous:   # Whisper repeats a line over silence
            continue
        previous = text
        for word in segment.get("words") or [{"word": text, "start": segment["start"], "end": segment["end"]}]:
            words.append((word["start"], word["end"], word["word"]))

    result = []
    for start, end, word in words:
        speaker = speaker_at(turns, start, end) if turns else None
        if result and result[-1][0] == speaker and start - result[-1][3] < PARAGRAPH_GAP:
            result[-1][2].append(word)
            result[-1][3] = end
        else:
            result.append([speaker, start, [word], end])
    return [(speaker, start, "".join(parts).strip()) for speaker, start, parts, _ in result]


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
    parser.add_argument("--speakers", type=int, help="how many voices, when known (default: guess)")
    parser.add_argument("--no-speakers", action="store_true", help="skip telling the voices apart")
    args = parser.parse_args()

    import mlx_whisper

    audio = load_audio(args.audio)
    log(f"Transcribing {args.audio.name}")
    result = mlx_whisper.transcribe(audio, path_or_hf_repo=args.model, language=args.language,
                                    condition_on_previous_text=False, word_timestamps=True)
    turns = []
    if not args.no_speakers:
        try:
            log("Telling the voices apart")
            turns = diarize(audio, args.speakers)
        except Exception as error:   # a transcript without speakers beats no transcript
            log(f"Speakers skipped: {error}")

    blocks = []
    for speaker, start, text in paragraphs(result.get("segments", []), turns):
        label = f"**Speaker {speaker}** " if speaker else ""
        blocks.append(f"{label}[{clock(start)}]\n{text}")
    body = "\n\n".join(blocks) or "_No speech found._"
    voices = len({speaker for _, _, speaker in turns})

    header = [f"# {args.title or args.audio.stem}", ""]
    for label, value in [("Meeting", args.meeting), ("Recorded", args.recorded), ("Length", args.minutes),
                         ("Language", result.get("language")), ("Voices", voices or None),
                         ("Audio", args.audio.name),
                         ("Made by", "Whisper large-v3-turbo (MLX) and sherpa-onnx, on this Mac")]:
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
