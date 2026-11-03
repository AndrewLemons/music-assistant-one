"""Audible seek oracle: native FLAC must fail, the companion's MP4 must pass."""
import json
from pathlib import Path
import platform
import subprocess
import tempfile
import uuid

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[2]


def docker_run(arguments):
    # A timeout must also stop the container, not just the Docker CLI process.
    name = "one-audible-" + uuid.uuid4().hex
    try:
        subprocess.run(["docker", "run", "--rm", "--pull", "never", "--name", name,
                        "--label", "one.playback-research=true", *arguments], check=True, timeout=120)
    finally:
        subprocess.run(["docker", "rm", "--force", name], capture_output=True)


def main(output, image):
    output = Path(output).resolve()
    output.mkdir(parents=True, exist_ok=True)
    image = image or "music-assistant-one-server:2.10.9"
    with tempfile.TemporaryDirectory(prefix="one-audible-seek-") as directory:
        temporary = Path(directory)
        docker = ["-v", f"{temporary}:/w"]
        docker_run([*docker, "--entrypoint", "ffmpeg", image, "-v", "error", "-f", "lavfi", "-i",
                    "aevalsrc=exprs='0.4*sin(2*PI*(200*t+5*t*t))|if(lt(t\\,120)\\,0.9*(random(0)*2-1)\\,0.001*sin(2*PI*50*t))':s=44100:d=240",
                    "-c:a", "flac", "-sample_fmt", "s16", "-f", "flac", "/w/chirp.flac"])
        docker_run([*docker, "-v", f"{ROOT / 'ServerCompanion'}:/companion:ro",
                    "-v", f"{HERE / 'fixture.py'}:/fixture.py:ro", "--entrypoint", "python", image, "/fixture.py"])
        probe = temporary / "probe"
        subprocess.run(["swiftc", "-O", "-parse-as-library", str(HERE / "probe.swift"), "-o", str(probe)],
                       check=True, timeout=120)
        results = {}
        for name, extension in [("native_flac", "flac"), ("companion_mp4", "m4a")]:
            result = subprocess.run([str(probe), str(temporary / ("chirp." + extension))],
                                    capture_output=True, text=True, timeout=60)
            (output / (name + ".jsonl")).write_text(result.stdout)
            (output / (name + ".stderr")).write_text(result.stderr)
            samples = [json.loads(line) for line in result.stdout.splitlines()]
            results[name] = dict(passed=result.returncode == 0, exit_code=result.returncode, seeks=samples)
            if len(samples) != 5 or result.returncode not in (0, 1):
                raise RuntimeError(f"{name}: probe failed to execute all seeks: {result.stderr}")
            print(name, json.dumps(results[name]), flush=True)
        passed = not results["native_flac"]["passed"] and results["companion_mp4"]["passed"]
        (output / "metrics.json").write_text(json.dumps(dict(
            platform=platform.platform(), passed=passed, results=results,
            note="Decoded PCM from a real AVPlayer audio tap; tolerance 1 s including capture latency and frequency quantization."), indent=2) + "\n")
        if not passed:
            raise RuntimeError("Audible seek regression: native control must fail and companion MP4 must pass")
