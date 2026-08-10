# Yoga audio generation and release runbook

ForgeFit uses `google/gemini-3.1-flash-tts-preview` through OpenRouter only as a build-time narrator. The iPhone app never calls OpenRouter during a class. Both selected instructor libraries ship as MP3 resources and play offline; missing or unapproved assets fall back to an on-device female or male system voice using the same visible transcript.

The current catalog contains 381 stable transcript IDs. Two instructors produce 762 manifest rows and, at present, 762 unique MP3s. At 96 kbps, the catalog command currently estimates roughly 64 MiB of bundled narration; actual size follows the measured output durations. The generator’s deliberately conservative pricing reserve is about $11.12, below the hard-coded $15 project cap. Always use the live `catalog` output as the authority because content revisions can change those numbers.

## Voice candidates

Google currently describes the shortlisted voices as follows:

| Role | Voice | Published character |
|---|---|---|
| Female | Vindemiatrix | Gentle |
| Female | Achernar | Soft |
| Female | Sulafat | Warm |
| Female | Despina | Smooth |
| Male | Orus | Firm |
| Male | Schedar | Even |
| Male | Algieba | Smooth |
| Male | Umbriel | Easy-going |

Orus remains in the male shortlist because it already sounded promising in ForgeFit’s initial listening. Voice labels are a starting point, not a selection result. Compare the actual guided-yoga audition with headphones and the iPhone speaker.

## Commands

Set the API key only in the current shell. The script never writes it to disk:

```sh
export OPENROUTER_API_KEY='…'
```

Inspect the exact free workload first:

```sh
scripts/generate_yoga_audio.py catalog
```

Generate the bounded eight-voice audition. This is billable and capped at $1:

```sh
scripts/generate_yoga_audio.py audition \
  --max-spend 1 \
  --confirm-billable
```

Open `artifacts/yoga-audio/auditions/index.html`, compare calmness, clarity, pace, pronunciation, consistency, and whether the voice stays grounded during physical instructions. Record the chosen female and male voice; do not infer approval merely from the provider’s descriptive label.

After explicit voice approval, run the resumable full batch. The currently approved audition result is Vindemiatrix for female guidance and Algieba for male guidance:

```sh
scripts/generate_yoga_audio.py batch \
  --female-voice Vindemiatrix \
  --male-voice Algieba \
  --voices-approved 'James approved Vindemiatrix and Algieba on 2026-08-09' \
  --max-spend 15 \
  --concurrency 4 \
  --confirm-billable
```

The generator:

- reads only approved app transcripts;
- adds calm/warm/clear or calm/warm/meditative delivery tags according to cue type;
- preserves the exact transcript while progressively simplifying only non-spoken delivery tags if the preview model repeatedly returns an empty stream;
- requests Gemini’s raw 24 kHz, 16-bit mono PCM from OpenRouter’s `/api/v1/audio/speech` endpoint and encodes it locally as MP3;
- retains the OpenRouter generation ID and queries its recorded cost when available;
- keeps the conservative reserve for the project hard cap, calibrates the separate credit-sufficiency check from same-model actual costs, and retains a safety margin;
- rechecks account credit periodically and stops in a resumable state if the remaining balance no longer covers the calibrated unfinished workload;
- stops before scheduling work that could exceed the $15 cap;
- retries bounded failures and resumes verified files from its ledger;
- normalizes narration to -18 LUFS / -2 dB true peak, 24 kHz mono, 96 kbps MP3;
- records exact transcript, duration, SHA-256, role, provider voice, filename, and generation ID in the app manifest.

Run the free verifier:

```sh
scripts/generate_yoga_audio.py verify
```

Listen to at least all audition lines, every Sanskrit pose name, every side-specific entry, all safety-critical option/exit clips, and a randomized sample from every other cue kind. After that human pass:

```sh
scripts/generate_yoga_audio.py verify --mark-approved \
  --listening-approved 'James completed the required listening pass on YYYY-MM-DD'
```

Only an `approved` manifest with both voice-audition and listening audit notes lets the settings UI describe the Gemini library as bundled. The verifier checks completeness, exact transcript mapping, hashes, decoding, mono 24 kHz format, duration, and non-silent/non-clipping signal. Approval does not replace physical-device checks.

## Physical-device release checks

- Female and male selection changes both image and the next spoken clip.
- Clips play with the screen locked and the timer remains wall-clock accurate.
- Music ducks for speech and returns during intentional silence.
- iPhone speaker, AirPods, Bluetooth, and route changes behave as expected.
- A call or Siri interruption pauses the class and never resumes it without the user.
- Pause, resume, skip, back, side switch, app backgrounding, and completion do not overlap or truncate narration.
- Captions match every spoken word and remain readable with narration muted, Dynamic Type, VoiceOver, Reduce Motion, and high-contrast settings.
- The built-in flow transitions are practiced on both sides at representative 15-, 30-, 60-, 120-, and 180-second holds.

Current provider references: [OpenRouter TTS API](https://openrouter.ai/docs/guides/overview/multimodal/tts), [OpenRouter model page](https://openrouter.ai/google/gemini-3.1-flash-tts-preview), [Gemini speech generation](https://ai.google.dev/gemini-api/docs/speech-generation), and [Google Gemini TTS voices](https://docs.cloud.google.com/text-to-speech/docs/gemini-tts).
