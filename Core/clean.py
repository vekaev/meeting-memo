"""Clean up a Meeting Memo transcript with Claude and put the clean version above the raw one.

Usage: python3 clean.py <note.md> [--me NAME] [--other NAME] [--model sonnet] [--claude PATH] [--force]

Only the transcript's text goes to Claude, through the `claude` CLI in print mode (no tools, no MCP
servers, no saved session, no user settings); the audio stays on the Mac. Long transcripts are cleaned
in parts; the first part settles who "Speaker 1", "Speaker 2"… are, and the rest keep those names.
Standard library only, so it runs with the system Python.
"""
from __future__ import annotations

import argparse
import pathlib
import re
import shutil
import subprocess
import sys

PART_WORDS = 2500
CLEAN = "## Clean transcript"
RAW = "## Raw transcript (Whisper)"

RULES = """You clean up an automatic transcript of a recorded conversation (Whisper speech recognition plus
automatic speaker detection). Output only the cleaned transcript, nothing before or after it.

- Keep the original language or languages. Never translate, summarise or paraphrase.
- Keep the format: a line "**Name** [mm:ss]", then that speaker's text, blocks separated by a blank
  line, in the original order and with the original timestamps. Merge consecutive blocks of the same
  speaker into one (keep the first timestamp); split a long block into paragraphs by thought.
- Fix punctuation, capitalisation and clearly misheard words from context (names, terms). Drop
  stutters and false starts only. Write [inaudible] for a word you cannot recover.
- Speaker detection makes mistakes: when a sentence clearly belongs to the other person (a question
  answered by the same "speaker", a change of voice in the middle of a block), move it to them.
- The recording's owner is {me}. {other_line}"""


def blocks(body: str) -> list[str]:
    return [block.strip() for block in re.split(r"\n\s*\n", body.strip()) if block.strip()]


def parts(items: list[str]) -> list[str]:
    result, current, words = [], [], 0
    for block in items:
        count = len(block.split())
        if current and words + count > PART_WORDS:
            result.append("\n\n".join(current))
            current, words = [], 0
        current.append(block)
        words += count
    if current:
        result.append("\n\n".join(current))
    return result


def ask(claude: str, model: str, system: str, text: str) -> str:
    done = subprocess.run(
        [claude, "-p", "--model", model, "--tools", "", "--no-session-persistence", "--strict-mcp-config",
         "--setting-sources", "", "--system-prompt", system, "--output-format", "text"],
        input=text, capture_output=True, text=True, timeout=900)
    if done.returncode != 0 or not done.stdout.strip():
        raise RuntimeError(f"claude failed: {done.stderr.strip()[:300]}")
    return done.stdout.strip()


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("note", type=pathlib.Path)
    parser.add_argument("--me", default="Me")
    parser.add_argument("--other", help="the other main speaker, e.g. Therapist")
    parser.add_argument("--model", default="sonnet")
    parser.add_argument("--claude", default=shutil.which("claude") or str(pathlib.Path.home() / ".local/bin/claude"))
    parser.add_argument("--force", action="store_true", help="clean again even if a clean version exists")
    args = parser.parse_args()

    note = args.note.read_text(encoding="utf-8")
    if CLEAN in note and not args.force:
        print(f"already clean: {args.note}")
        return
    header, _, rest = note.partition("\n## ")
    rest = "## " + rest
    # The raw transcript, whichever way the note was saved before.
    raw = rest.split(RAW, 1)[1] if RAW in rest else rest.split("## Transcript", 1)[1]
    raw = raw.strip()

    other_line = (f"The other main speaker is {args.other}. Name the speakers \"{args.me}\" and \"{args.other}\" "
                  "where the content makes it clear who is who; anyone else stays \"Speaker N\".") if args.other else \
                 f"Name the owner \"{args.me}\" where it is clear; everyone else stays \"Speaker N\"."
    system = RULES.format(me=args.me, other_line=other_line)

    cleaned, names = [], None
    chunks = parts(blocks(raw))
    for index, chunk in enumerate(chunks, 1):
        print(f"cleaning part {index}/{len(chunks)}", file=sys.stderr, flush=True)
        if names is None:
            prompt = system + "\n\nBegin your answer with one line \"NAMES: Speaker 1 = …; Speaker 2 = …\" " \
                              "listing the name you gave each speaker label, then a blank line, then the transcript."
            answer = ask(args.claude, args.model, prompt, chunk)
            first, _, answer = answer.partition("\n")
            names = first.removeprefix("NAMES:").strip() if first.startswith("NAMES:") else ""
            if not first.startswith("NAMES:"):
                answer = first + "\n" + answer
        else:
            prompt = system + (f"\n\nEarlier parts used these names; keep them: {names}." if names else "")
            answer = ask(args.claude, args.model, prompt, chunk)
        cleaned.append(answer.strip())

    lines = header.rstrip().split("\n")
    lines.append(f"- Cleaned by: Claude ({args.model}), from the text only")
    if names:
        lines.append(f"- Speakers: {names}")
    result = "\n".join(lines) + f"\n\n{CLEAN}\n\n" + "\n\n".join(cleaned) + f"\n\n{RAW}\n\n" + raw + "\n"
    temp = args.note.with_name("." + args.note.name + ".partial")
    temp.write_text(result, encoding="utf-8")
    temp.replace(args.note)
    print(args.note)


if __name__ == "__main__":
    try:
        main()
    except Exception as error:
        print(f"clean failed: {error}", file=sys.stderr)
        sys.exit(1)
