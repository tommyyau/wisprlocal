# Frozen experiments

- S1 (`S1-parakeet/RESULTS.md`): measured offline Parakeet v2 latency, memory, VAD bounds and vocabulary boosting; informs local model loading, silence trimming and the replacement dictionary.
- S1b (`S1b-models/RESULTS.md`): compared model accuracy, preparation, switching, memory and soak stability; supplies the speech-model figures in TEST_REPORT and model-choice help.
- S2 (`S2-keystrokes/README.md`, no RESULTS.md): compares Unicode, keycodes and delayed paste over Screen Sharing; informs remote insertion strategies, with manual results still pending.
- S3 (`S3-cleanup/RESULTS.md`): measured rule cleanup and tested an early output guard; Foundation Models was unavailable, and later app measurements and guard designs are in TEST_REPORT §6.
- S4 (`S4-speaker/RESULTS.md`): measured synthetic speaker-embedding separation and overlapping voices; informs planned speaker focus, which is not built.
- S5 (`S5-live/RESULTS.md`): measured live-preview cost and rewrites and probed Translation availability; informs proposed preview/translation designs, which are not shipped.

Audio, model files and builds are git-ignored. S4’s legacy speaker weights are not redistributable.
