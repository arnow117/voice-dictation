"""Runtime evidence for production Qwen3 chunk decoding, using only public benchmark fixtures."""
import json
import subprocess
import sys
import tempfile
import wave
from pathlib import Path


def read_frames(path):
    with wave.open(str(path), "rb") as source:
        params = source.getparams()
        return params, source.readframes(source.getnframes())


def padded_chunk(frames, frame_width, target_frames):
    kept = frames[: target_frames * frame_width]
    return kept + b"\0" * (target_frames * frame_width - len(kept))


def write_runtime_fixtures(directory, clips):
    first_params, first = read_frames(clips / "zh-001.wav")
    final_params, final = read_frames(clips / "zh-002.wav")
    if first_params[:3] != final_params[:3]:
        raise RuntimeError("public fixture formats must match")

    rate, channels, width = first_params.framerate, first_params.nchannels, first_params.sampwidth
    chunk_frames = rate * 20
    frame_width = channels * width
    long_path = directory / "public-fixture-180s.wav"
    with wave.open(str(long_path), "wb") as output:
        output.setparams(first_params)
        for _ in range(8):
            output.writeframes(padded_chunk(first, frame_width, chunk_frames))
        output.writeframes(padded_chunk(final, frame_width, chunk_frames))

    silence_path = directory / "silence-20s.wav"
    with wave.open(str(silence_path), "wb") as output:
        output.setparams(first_params)
        output.writeframes(b"\0" * chunk_frames * frame_width)
    return long_path, silence_path


def main():
    binary, clips = sys.argv[1], Path(sys.argv[2])
    with tempfile.TemporaryDirectory(prefix="shanshuo-asr-") as temporary:
        long_path, silence_path = write_runtime_fixtures(Path(temporary), clips)
        completed = subprocess.run(
            [binary, "--transcribe", str(long_path), str(silence_path)],
            capture_output=True,
            text=True,
            timeout=1200,
        )
        rows = [json.loads(line) for line in completed.stdout.splitlines() if line.startswith("{")]
        results = {row["file"]: row for row in rows if "file" in row}

        long = results.get(long_path.name)
        silence = results.get(silence_path.name)
        if completed.returncode != 0 or long is None or silence is None:
            print("FAIL: the production CLI did not return both runtime fixtures")
            sys.exit(1)
        if long["audio_s"] != 180 or long["chunk_count"] != 9 or long["decoded_chunk_count"] != 9:
            print("FAIL: 180-second fixture was not decoded as nine production chunks")
            sys.exit(1)
        if "金属" not in long["text"]:
            print("FAIL: expected public-fixture end segment was absent")
            sys.exit(1)
        if silence["text"] or silence["decoded_chunk_count"] != 0:
            print("FAIL: zero-signal audio must not create a transcript")
            sys.exit(1)

        print(
            "ASR chunk runtime passed: 180 s / 9 chunks / final public-fixture segment present; "
            "zero-signal fixture produced no transcript"
        )


if __name__ == "__main__":
    main()
