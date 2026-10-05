#!/usr/bin/env python3
"""Generate S1b fixtures: dictation utterances via `say`, plus noisy mixes.

Output: Fixtures/clean/*.wav, Fixtures/noisy/*.wav, Fixtures/manifest.json
All WAVs are 16 kHz mono int16. Deterministic (seeded) so reruns are identical.

Noise conditions (level of the interferer relative to the target speech RMS):
  tv10    : TV-like speech (other `say` voices, band-limited 200-4000 Hz) at -10 dB  (SNR +10 dB)
  tv6     : same TV-like speech at -6 dB                                             (SNR +6 dB)
  music10 : synthesised chord progression (harmonic tones + soft percussion) at -10 dB (SNR +10 dB)
"""
import json, os, subprocess, tempfile, wave
import numpy as np

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
FIX = os.path.join(ROOT, "Fixtures")
SR = 16000
rng = np.random.default_rng(1234)

# (id, voice, spoken text == reference text, jargon terms)
UTTS = [
    ("u01", "Daniel", "Open Wispr Flow and start a new dictation session.", ["Wispr Flow"]),
    ("u02", "Samantha", "Can you check whether the Tailscale node in Frankfurt is still online?", ["Tailscale"]),
    ("u03", "Karen", "The Kubernetes cluster has twelve pods stuck in a crash loop.", ["Kubernetes"]),
    ("u04", "Moira", "Please send the Grafana dashboard link to Priya before the stand-up.", ["Grafana", "Priya"]),
    ("u05", "Rishi", "My email address is alex@example.com, please reply by Friday.", ["alex@example.com"]),
    ("u06", "Daniel", "Schedule a call with Sarah Chen and Diego Alvarez for half past three tomorrow.", ["Sarah Chen", "Diego Alvarez"]),
    ("u07", "Tessa", "Restart the Grafana agent, then tail the logs on the Kubernetes control plane.", ["Grafana", "Kubernetes"]),
    ("u08", "Flo (English (UK))", "I've pushed the fix to the main branch, the build should take about 4 minutes.", []),
    ("u09", "Eddy (English (UK))", "Remind me to renew the Tailscale licence on the 3rd of March.", ["Tailscale"]),
    ("u10", "Reed (English (UK))", "Wispr Flow costs $15 a month, but this app runs entirely offline.", ["Wispr Flow"]),
    ("u11", "Samantha", "Set the Grafana alert threshold to 85 percent CPU for 10 minutes.", ["Grafana"]),
    ("u12", "Shelley (English (UK))", "Forward the invoice to accounts@example.org and copy in Marcus.", ["accounts@example.org", "Marcus"]),
    ("u13", "Daniel", "The Kubernetes upgrade to version 1.31 is scheduled for the 14th of November.", ["Kubernetes"]),
    ("u14", "Moira", "Tell Marcus that the Tailscale exit node in Dublin is back up.", ["Marcus", "Tailscale"]),
    ("u15", "Rishi", "Grafana shows a latency spike of 250 milliseconds on the checkout service.", ["Grafana"]),
    ("u16", "Karen", "Turn on Wispr Flow, dictate the notes, and paste them into Slack.", ["Wispr Flow", "Slack"]),
    ("u17", "Tessa", "Book a table for 6 people at 7:30 on Saturday evening.", []),
    ("u18", "Eddy (English (UK))", "Sarah Chen approved the pull request, so we can deploy to Kubernetes this afternoon.", ["Sarah Chen", "Kubernetes"]),
    ("u19", "Samantha", "Quick update for the team. The Tailscale rollout is finished, Grafana alerts are routed to the on-call channel, and the Kubernetes migration is about eighty percent done. I'll send a full summary to everyone@example.com by Thursday.", ["Tailscale", "Grafana", "Kubernetes", "everyone@example.com"]),
    ("u20", "Daniel", "Draft an email to Nikolai saying the Wispr Flow prototype now transcribes offline in under a hundred milliseconds, and ask whether he can test it on his MacBook Pro next week.", ["Nikolai", "Wispr Flow"]),
    ("u21", "Flo (English (UK))", "Honestly, I think we should just ship it on Monday and fix the small bugs afterwards.", []),
    ("u22", "Reed (English (UK))", "What's the weather going to be like in Manchester this weekend?", ["Manchester"]),
]

TV_TEXT = [
    ("Ralph", "Good evening and welcome to the six o'clock news. Tonight, heavy rain has caused flooding across the north of the country, and transport officials are warning commuters to expect delays tomorrow morning."),
    ("Grandpa (English (US))", "In sport, the home side came from behind to win three two, with a late goal in the final minute sending the crowd into celebration."),
    ("Fred", "Stocks closed higher today as investors welcomed news that inflation had eased for the third month in a row, though analysts cautioned that energy prices remain volatile."),
    ("Kathy", "And finally, a family of ducks brought traffic to a standstill on the high street this afternoon, as police officers helped them cross safely to the river."),
]


def say_to_array(voice, text):
    with tempfile.TemporaryDirectory() as td:
        aiff = os.path.join(td, "a.aiff"); wav = os.path.join(td, "a.wav")
        subprocess.run(["say", "-v", voice, "-o", aiff, text], check=True)
        subprocess.run(["afconvert", "-f", "WAVE", "-d", "LEI16@16000", "-c", "1", aiff, wav], check=True,
                       stdout=subprocess.DEVNULL)
        return read_wav(wav)


def read_wav(path):
    with wave.open(path) as w:
        assert w.getframerate() == SR and w.getnchannels() == 1
        x = np.frombuffer(w.readframes(w.getnframes()), dtype=np.int16).astype(np.float32) / 32768.0
    return x


def write_wav(path, x):
    x = np.clip(x, -1.0, 1.0)
    with wave.open(path, "wb") as w:
        w.setnchannels(1); w.setsampwidth(2); w.setframerate(SR)
        w.writeframes((x * 32767).astype(np.int16).tobytes())


def active_rms(x):
    # RMS over frames above -40 dBFS-ish (ignore silence so SNR reflects speech level)
    fr = 400
    n = len(x) // fr
    e = np.sqrt(np.mean(x[: n * fr].reshape(n, fr) ** 2, axis=1) + 1e-12)
    thr = max(e.max() * 0.03, 1e-4)
    return float(np.sqrt(np.mean(e[e > thr] ** 2)))


def bandpass(x, lo=200.0, hi=4000.0):
    X = np.fft.rfft(x)
    f = np.fft.rfftfreq(len(x), 1 / SR)
    X[(f < lo) | (f > hi)] = 0
    return np.fft.irfft(X, n=len(x)).astype(np.float32)


def make_music(n):
    # I-V-vi-IV progression, 1.2 s per chord, harmonic tones with ADSR + soft hi-hat noise
    t = np.arange(n) / SR
    chords = [[261.63, 329.63, 392.00], [196.00, 246.94, 392.00], [220.00, 261.63, 329.63], [174.61, 220.00, 349.23]]
    out = np.zeros(n, dtype=np.float32)
    dur = int(1.2 * SR)
    for start in range(0, n, dur):
        ch = chords[(start // dur) % 4]
        seg = np.arange(min(dur, n - start)) / SR
        env = np.minimum(seg / 0.03, 1.0) * np.exp(-seg * 1.5)
        s = np.zeros_like(seg)
        for f0 in ch + [ch[0] / 2]:
            for h, a in ((1, 1.0), (2, 0.5), (3, 0.25), (4, 0.12)):
                s += a * np.sin(2 * np.pi * f0 * h * seg + rng.uniform(0, 6.28))
        out[start:start + len(seg)] += (env * s).astype(np.float32)
    beat = int(0.3 * SR)
    for start in range(0, n, beat):
        m = min(int(0.05 * SR), n - start)
        out[start:start + m] += (rng.standard_normal(m) * np.exp(-np.arange(m) / 200.0) * 0.6).astype(np.float32)
    return out


def mix(speech, noise, rel_db):
    pad = int(0.5 * SR)
    s = np.concatenate([np.zeros(pad, np.float32), speech, np.zeros(pad, np.float32)])
    nz = noise[: len(s)]
    gain = active_rms(speech) * (10 ** (rel_db / 20.0)) / (np.sqrt(np.mean(nz ** 2)) + 1e-12)
    y = s + gain * nz
    peak = np.max(np.abs(y))
    if peak > 0.98:
        y = y * (0.98 / peak)
    return y


def main():
    os.makedirs(os.path.join(FIX, "clean"), exist_ok=True)
    os.makedirs(os.path.join(FIX, "noisy"), exist_ok=True)
    manifest = []
    # S1 clips (Samantha), copied from S1-parakeet
    for cid in ("clip05", "clip30", "clip60"):
        ref = open(os.path.join(FIX, "s1", cid + ".txt")).read().strip()
        jar = [j for j in ["Wispr Flow", "Tailscale", "Kubernetes", "Grafana", "Postgres", "Priya", "Marcus", "Helm",
                           "Argo CD", "Parakeet", "Sarah Chen", "Diego Alvarez", "Slack"] if j in ref]
        x = read_wav(os.path.join(FIX, "s1", cid + ".wav"))
        manifest.append(dict(id=cid, file=f"s1/{cid}.wav", ref=ref, jargon=jar, cond="clean", voice="Samantha",
                             set="s1", dur=round(len(x) / SR, 2)))

    # TV babble bed (~70 s), band-limited
    tv = np.concatenate([say_to_array(v, t) for v, t in TV_TEXT] * 2)
    tv = bandpass(tv)
    music = make_music(int(40 * SR))

    for uid, voice, text, jar in UTTS:
        x = say_to_array(voice, text)
        write_wav(os.path.join(FIX, "clean", uid + ".wav"), x)
        d = len(x) / SR
        manifest.append(dict(id=uid, file=f"clean/{uid}.wav", ref=text, jargon=jar, cond="clean", voice=voice,
                             set="utt", dur=round(d, 2)))
        n = len(x) + SR
        off = int(rng.integers(0, len(tv) - n))
        moff = int(rng.integers(0, len(music) - n)) if len(music) > n else 0
        mus = music if len(music) >= n + moff else np.tile(music, 2)
        for cond, noise, db in (("tv10", tv[off:off + n], -10), ("tv6", tv[off:off + n], -6),
                                ("music10", mus[moff:moff + n], -10)):
            y = mix(x, noise, db)
            fn = f"noisy/{uid}_{cond}.wav"
            write_wav(os.path.join(FIX, fn), y)
            manifest.append(dict(id=f"{uid}_{cond}", file=fn, ref=text, jargon=jar, cond=cond, voice=voice,
                                 set="utt", dur=round(len(y) / SR, 2)))
    # ~4 min long-form clip (probe FluidAudio #954: duplicated words at window merges)
    long_ref = " ".join([open(os.path.join(FIX, "s1", c + ".txt")).read().strip() for c in ("clip60", "clip30")]
                        + [u[2] for u in UTTS])
    x = say_to_array("Daniel", long_ref)
    write_wav(os.path.join(FIX, "clean", "long4m.wav"), x)
    manifest.append(dict(id="long4m", file="clean/long4m.wav", ref=long_ref,
                         jargon=["Wispr Flow", "Tailscale", "Kubernetes", "Grafana"], cond="clean", voice="Daniel",
                         set="long", dur=round(len(x) / SR, 2)))
    with open(os.path.join(FIX, "manifest.json"), "w") as f:
        json.dump(manifest, f, indent=1)
    durs = [m["dur"] for m in manifest if m["cond"] == "clean" and m["set"] == "utt"]
    print(f"{len(manifest)} fixtures; clean utt durations {min(durs):.1f}-{max(durs):.1f}s")


if __name__ == "__main__":
    main()
