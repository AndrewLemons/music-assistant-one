# Audible seek accuracy

`probe.swift` seeks a real AVPlayer and measures what is audible through an audio tap. The
left channel of the test file is a chirp, f(t) = 200 + 10 t Hz, so its frequency gives the true
position. The right channel alternates loud noise and near-silence to make the bitrate vary, as
music does.

```sh
docker run --rm -v "$PWD":/w --entrypoint ffmpeg ghcr.io/music-assistant/server:2.10.9 -y \
  -f lavfi -i "aevalsrc=exprs='0.4*sin(2*PI*(200*t+5*t*t))|if(lt(t\,120)\,0.9*(random(0)*2-1)\,0.001*sin(2*PI*50*t))':s=44100:d=240" \
  -c:a flac -sample_fmt s16 -f flac /w/chirp.flac
swiftc -O -parse-as-library -o probe probe.swift && ./probe chirp.flac
```

On November 3, 2026 (macOS 27.2), native FLAC seeked inaccurately while AVPlayer reported the
requested time: 150 s played from 236.5 s; 200 s and 230 s played nothing. A SEEKTABLE did not
help. The same FLAC stream in MP4 (`-c:a copy -f mp4`) and ALAC both played within the probe's
constant 0.3 s latency at every target.

Run the automated regression from the repository root:

```sh
make server-image
python3 scripts/benchmark-playback.py --reliability --audible-seek --output /tmp/one-audible-seek
```

The harness generates the native FLAC control above, decodes it to PCM, and feeds the real
companion's dual-output encoder to produce faststart FLAC-in-MP4 plus HLS. It compiles the
probe and requires all five MP4 seeks to pass and the native control to fail. The probe also
runs directly (`./probe file.m4a`): exit 0 means every target passed; exit 1 means an inaccurate
seek or missing signal. JSONL contains requested/reported times, the position inferred from
PCM zero crossings, signal sample counts, and per-seek results. An unsupported tap format,
failed asset, missing seek, or crashed probe cannot satisfy the negative control.

Only frames actually returned by the tap are measured. A 100 ms chirp window gives about
0.5 seconds of position quantization, and the tap runs ahead of the output clock by about
0.3 seconds. The oracle permits at most one second between the inferred and reported
positions (and 1.5 seconds from the requested target). Silence fails. The runner removes its
fixtures, native executable and containers on exit, retaining JSONL and metrics at `--output`.
This measures decoded audio, independently of AVPlayer's reported time; it does not measure
physical iPhone speaker output.
