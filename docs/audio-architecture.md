# FocusMate — Audio Architecture & Reference

> **Scope.** This document covers *only* the audio subsystem: how indefinite
> ambient playback works, which library we use and why, how synthesized and
> recorded sounds coexist, and the best practices that keep it robust. The rest
> of the app (Rails CRUD, the Pomodoro timer state machine) is conventional and
> out of scope here. This is the part of the project that was genuinely unknown,
> so this doc is written to be *studied*, not just skimmed.

---

## 1. The one idea that dissolves the hard problem

The original worry was: *"users play audio indefinitely — does the server stream
a never-ending loop?"*

**No. Looping is a client concern. The server is never involved in playback.**

Rails (or a CDN) hands the browser a finite audio file **once**, or the browser
generates the sound from nothing. From then on the browser loops/generates it
locally — forever — with zero further server contact. A 90-second clip looped
client-side plays for 8 hours at no streaming cost and ties up no Puma worker.

Everything below is therefore **front-end engineering**. The backend's only audio
responsibility is to emit correct asset URLs for the handful of recorded sounds.

---

## 2. The mental model: a node graph, not a "player"

The Web Audio API (which Tone.js sits on top of) is not "play this file." It is a
**signal graph** of nodes. Sources flow through processors into the speakers:

```
SOURCES                       PER-LAYER VOLUME        MASTER BUS
─────────────────────         ────────────────        ──────────────────
Noise (white/pink/brown) ───► gain ─┐
Oscillator (gamma/alpha) ───► gain ─┼──► master gain ──► limiter ──► 🔊
Player (forest.m4a, loop) ──► gain ─┘                   (clip safety)
```

Three node families:

| Family       | Examples                                   | Role                     |
|--------------|--------------------------------------------|--------------------------|
| **Sources**  | `Noise`, `Oscillator`, `Player` (buffer)   | Generate / play audio    |
| **Processors** | `Gain`, `Filter`, `Panner`, `Limiter`, `Reverb` | Shape / route / mix |
| **Destination** | `Tone.getDestination()` (the speakers)  | Terminal sink            |

**Why this matters for FocusMate specifically:** the planned "mix multiple
sounds with individual volumes" feature *is* this diagram. Each sound is a source
→ its own gain (= its slider) → the shared master. Mixing isn't a feature you
build; it's the native shape of the graph. Adding a sound to the mix = connect a
branch. Removing it = disconnect.

---

## 3. Library decision: Tone.js

We use **[Tone.js](https://tonejs.github.io/)** — a higher-level wrapper over the
raw Web Audio API — loaded via Rails **importmap** (no build step). It is
100% client-side.

### Why Tone.js over raw Web Audio

The mixer roadmap is the deciding factor. Tone.js ships, out of the box, exactly
the primitives we'd otherwise hand-roll:

- `Tone.Noise` — white / pink / brown noise generators (no manual buffer filling).
- `Tone.Oscillator`, `Tone.LFO` — tones and modulators for the "waves" sounds.
- `Tone.Player` — file playback with sample-accurate looping.
- `Tone.Gain` / `Tone.Channel` — per-layer volume, mute, solo, pan, and a
  send/receive **bus** system that models a mixing desk directly.
- `Tone.Limiter` / `Tone.Compressor` — master-bus clip protection.
- Smooth parameter ramps (`.rampTo`) so volume changes never click.

### What we are *not* using

- **Howler.js** — file-playback / sprite oriented, weak at synthesis. Wrong tool
  for a hybrid synth+file mixer.
- **Raw Web Audio only** — viable and dependency-free, but you re-implement noise
  buffers, gain bookkeeping, and the bus by hand. Section 9 shows the raw
  equivalents so the abstraction stays transparent — but Tone.js is the default.

### The cost

One JS dependency. Acceptable given how much of the mixer it provides for free.

---

## 4. Sound taxonomy: synthesized vs. recorded (the hybrid)

Two source types, **freely mixable on the same bus** because the mixer doesn't
care what a layer *is*:

| Sound            | Type        | How                                              |
|------------------|-------------|--------------------------------------------------|
| White noise      | Synthesized | `Tone.Noise("white")`                            |
| Pink noise       | Synthesized | `Tone.Noise("pink")` — softer, more natural      |
| Brown noise      | Synthesized | `Tone.Noise("brown")` — deep rumble              |
| Gamma waves      | Synthesized | Carrier + 40 Hz amplitude modulation (LFO)       |
| Alpha waves      | Synthesized | Carrier + ~10 Hz amplitude modulation (LFO)      |
| Forest ambience  | **Recorded** | `Tone.Player("forest.m4a", { loop: true })`     |
| River ambience   | **Recorded** | `Tone.Player("river.m4a",  { loop: true })`     |

**Rule of thumb:** noise and oscillator-based textures are synthesized (zero
assets, infinite length trivially). Real-world scenes (forest, river, rain, café)
are field recordings — they can't be synthesized convincingly. You author or
download these (CC sources like [Freesound](https://freesound.org/)) and ship
them with the repo.

---

## 5. Synthesis recipes

### 5.1 Noise

```js
// Tone.js — trivial
const noise = new Tone.Noise("pink").start();   // "white" | "pink" | "brown"
```

Pink and brown are *filtered* white noise (less harsh high end). Pink is usually
the most pleasant focus background.

### 5.2 "Gamma / alpha waves" — amplitude modulation

These are brainwave-entrainment concepts. Two honest implementations:

**Isochronic / AM (recommended — pleasant, mono-safe).** A carrier whose volume
pulses at the target rate via an LFO driving a gain:

```js
const carrier = new Tone.Noise("pink").start();      // or an Oscillator
const depth   = new Tone.Gain(0);                     // modulated gain
const lfo     = new Tone.LFO({ frequency: 40,         // 40 Hz = gamma; ~10 Hz = alpha
                               min: 0.2, max: 1 }).start();
lfo.connect(depth.gain);                              // LFO modulates amplitude
carrier.connect(depth);
// depth → layer gain → master (see §6)
```

**Binaural (alternative).** Two oscillators detuned by the target frequency,
panned hard left/right. Requires stereo and headphones:

```js
const left  = new Tone.Oscillator(200, "sine").connect(new Tone.Panner(-1)).start();
const right = new Tone.Oscillator(240, "sine").connect(new Tone.Panner( 1)).start();
// 240 - 200 = 40 Hz perceived "gamma" beat
```

> **Honesty note.** The neuroscience of entrainment is contested. As an *audio
> feature* it is trivial and pleasant; we ship it as ambience, not as a medical
> claim.

### 5.3 Faux nature from noise (optional)

Brown noise → lowpass filter with slowly modulated cutoff approximates rushing
water surprisingly well. Useful as a fallback, but real recordings win for
forest/river — hence the hybrid.

---

## 6. The mixer architecture

This is the heart of the system and the thing the roadmap depends on.

### 6.1 Per-layer gain → master bus → limiter

```
each source ──► Tone.Channel(volume, mute, solo) ──► master Gain ──► Tone.Limiter ──► destination
```

- **Each layer owns a `Tone.Channel`** (or a plain `Tone.Gain`). Its volume *is*
  the slider. Mute/solo come free with `Tone.Channel`.
- **All channels sum into one master gain**, then a **`Tone.Limiter`**.

### 6.2 Why the limiter is non-negotiable when mixing

Simultaneous layers **add** in amplitude. Three sounds at full volume can sum past
the [-1, 1] range → harsh digital clipping. Defenses:

1. Master gain with **headroom** (e.g. 0.8).
2. A **`Tone.Limiter(-3)`** (or `Compressor`) on the master to catch peaks.

```js
const limiter = new Tone.Limiter(-3).toDestination();
const master  = new Tone.Gain(0.8).connect(limiter);
// every layer's channel connects to `master`
```

### 6.3 Always ramp gains, never assign

Instant `.value` changes click. Use ramps:

```js
layer.channel.volume.rampTo(dbValue, 0.05);   // 50 ms — inaudible, click-free
```

> **Units gotcha.** `Tone.Gain.gain` is **linear** (0–1). `Tone.Channel.volume`
> and `Tone.Volume` are in **decibels** (−Infinity … 0 dB). Pick one convention
> for the UI. A 0–100 slider maps cleanly to linear gain; if using dB, convert
> (e.g. `Tone.gainToDb(slider/100)`).

---

## 7. The layer abstraction (keeps the mixer from sprawling)

Hide the source type behind a uniform "layer" so the UI treats synth and file
identically:

```js
// A registry maps sound id → a factory that builds its source node.
const SOUND_REGISTRY = {
  white:  () => new Tone.Noise("white"),
  pink:   () => new Tone.Noise("pink"),
  gamma:  () => buildModulatedNoise(40),     // §5.2
  alpha:  () => buildModulatedNoise(10),
  forest: () => new Tone.Player({ url: forestUrl, loop: true }),
  river:  () => new Tone.Player({ url: riverUrl,  loop: true }),
};

function createLayer(id, master) {
  const source  = SOUND_REGISTRY[id]();
  const channel = new Tone.Channel().connect(master);
  source.connect(channel);
  return { id, source, channel };
}
```

A layer is `{ id, source, channel }` regardless of whether `source` is a
generator or a `Player`. Adding a new sound = **one registry entry**. The mixer
UI (slider, mute, solo) never branches on type.

---

## 8. File-based sounds (the recorded half)

### 8.1 `Tone.Player` and gapless looping

```js
const player = new Tone.Player({
  url: forestUrl,
  loop: true,
  loopStart: 0,
  loopEnd: 0,        // 0 = end of buffer
  fadeIn: 0.1,
  fadeOut: 0.1,
}).connect(channel);
```

`Tone.Player` decodes the file to a PCM buffer and loops it **sample-accurately**
— so there's no MP3 encoder-padding gap (the classic "gapless playback" bug).
The looping *mechanism* is perfect.

### 8.2 The seam is an *authoring* problem, not a code problem

Even with sample-accurate looping, if the **content** at `loopEnd` doesn't match
`loopStart`, you'll hear the scene "restart." Fix it in your DAW:

- Author the asset as a **seamless loop** — equal-power crossfade the tail into
  the head.
- Ambient textures (water, wind, leaves) hide seams extremely well, so this is
  easy for our sound set.

### 8.3 Codec & container — pick for cross-browser decode

Decoding goes through Web Audio's `decodeAudioData`, so browser codec support is
the constraint:

| Format        | Chrome/Firefox | Safari        | Verdict                         |
|---------------|----------------|---------------|---------------------------------|
| **AAC / .m4a** | ✅             | ✅            | **Default — safest cross-browser** |
| OGG / Opus    | ✅             | ⚠️ patchy     | Great elsewhere, risky on Safari |
| MP3           | ✅             | ✅            | Fine for `Player` (buffer loop avoids the padding gap) |
| WAV           | ✅             | ✅            | Lossless but large — avoid shipping |

Ship **AAC in `.m4a`**, or provide multiple formats. Small bitrate is fine —
ambient is forgiving; ~96–128 kbps is plenty.

### 8.4 Preloading & ready state

Synth layers are instant; files need a fetch + decode. Gate the UI on load:

```js
await Tone.loaded();        // resolves when all Player buffers are decoded
```

### 8.5 Loudness normalization

Normalize **all** sounds (synth and recorded) to a consistent perceived loudness
so switching layers or nudging a slider doesn't jump. Do this when authoring the
assets; for synth, tune the source gains to match.

---

## 9. Raw Web Audio equivalents (so the abstraction stays transparent)

Tone.js hides these, but understanding them is worth it. The same graph, by hand:

```js
const ctx = new (window.AudioContext || window.webkitAudioContext)();

// White noise source = a looping buffer of random samples
function whiteNoise(ctx) {
  const buf = ctx.createBuffer(1, ctx.sampleRate * 2, ctx.sampleRate);
  const data = buf.getChannelData(0);
  for (let i = 0; i < data.length; i++) data[i] = Math.random() * 2 - 1;
  const src = ctx.createBufferSource();
  src.buffer = buf; src.loop = true;
  return src;
}

// Per-layer gain → master → limiter → speakers
const master  = ctx.createGain();   master.gain.value = 0.8;
const limiter = ctx.createDynamicsCompressor();   // crude limiter
master.connect(limiter); limiter.connect(ctx.destination);

const layerGain = ctx.createGain(); layerGain.gain.value = 0.5;
const src = whiteNoise(ctx);
src.connect(layerGain); layerGain.connect(master);
src.start();

// Click-free volume change:
layerGain.gain.setTargetAtTime(0.2, ctx.currentTime, 0.05);
```

`Tone.Noise`, `Tone.Channel`, `Tone.Limiter`, and `.rampTo` are wrappers over
exactly this. Nothing magical — just less boilerplate and a bus system.

---

## 10. Critical best practices & gotchas

1. **AudioContext autoplay policy.** Browsers start the context **suspended**.
   You must resume it from a **user gesture** (the first Play click), or you get
   silence with no error. With Tone.js:
   ```js
   document.querySelector("#play").addEventListener("click", async () => {
     await Tone.start();   // resumes the context — must be in a gesture handler
   });
   ```
2. **One `AudioContext` per page.** Creating many leaks resources and hits browser
   limits. Tone.js gives you a single shared context.
3. **Always ramp gains** (`.rampTo` / `setTargetAtTime`) — never assign `.value`
   directly during playback. Instant changes click.
4. **Limiter on the master** whenever layers can stack (§6.2).
5. **Loudness-normalize** across all sounds (§8.5).
6. **Author seamless loops** for recordings (§8.2).
7. **Stop ≠ disconnect.** Stop the source *and* disconnect/dispose nodes when a
   layer is removed, or you leak nodes. Tone.js: call `.dispose()`.
8. **Mobile.** iOS is strict about gestures and silent-switch behavior; test on a
   real device. Background playback may be limited by the OS.

---

## 11. Rails / Stimulus integration

The audio engine is 100% client-side. Rails' only job is emitting asset URLs.

- **Library load:** pin Tone.js in `importmap.rb` (no build step).
- **Engine owner:** a single Stimulus controller, e.g. `audio_controller.js`,
  owns the shared context, the master bus, and the `{ id → layer }` map.
- **Asset URLs:** field recordings live in `app/assets` (or `public/`),
  fingerprinted and CDN-cached by the asset pipeline. Pass the fingerprinted URL
  into the controller via a `data-` attribute (`asset_path("forest.m4a")` on the
  Rails side) — never hardcode paths in JS.
- **State persistence:** which layers are active and their volumes are user
  preferences. Start with `localStorage`; promote to a small Rails JSON endpoint
  if cross-device sync is wanted later.

Sketch:

```erb
<div data-controller="audio"
     data-audio-forest-url-value="<%= asset_path('audio/forest.m4a') %>"
     data-audio-river-url-value="<%= asset_path('audio/river.m4a') %>">
  <button data-action="audio#toggle">Play</button>
  <!-- per-sound rows with sliders bound to audio#setVolume -->
</div>
```

---

## 12. Roadmap: the multi-source mixer

The architecture is already shaped for it (§6, §7). Delivering the feature means
UI, not re-architecture:

- Render every sound as a row with its own **volume slider** + **mute/solo**.
- Each active sound is a layer (`createLayer`) on the shared master bus.
- Persist the mix (active ids + volumes) per §11.
- Because synth and file layers are interchangeable on the bus, "white noise +
  gamma + forest, each at its own level" works the day the UI exists.

---

## 13. References

- **MDN — Web Audio API:** https://developer.mozilla.org/en-US/docs/Web/API/Web_Audio_API
- **MDN — Autoplay guide:** https://developer.mozilla.org/en-US/docs/Web/Media/Autoplay_guide
- **Tone.js docs:** https://tonejs.github.io/
- **Tone.js — `Player`:** https://tonejs.github.io/docs/latest/classes/Player
- **Tone.js — `Channel` (bus system):** https://tonejs.github.io/docs/latest/classes/Channel
- **Freesound (CC field recordings):** https://freesound.org/
- **Web Audio noise generation primer:** https://noisehack.com/generate-noise-web-audio-api/
