# Speech test fixture provenance

`clip05.wav` is synthetic formant speech generated from the repository-authored
`clip05.txt` using eSpeak NG 1.52.0 on 2026-10-04. It uses the built-in `en-us`
voice at 175 words per minute and pitch 50, without the final sentence pause.
`afconvert` resamples the output to 16 kHz mono 16-bit PCM.

The fixture contains no Apple system voice, sampled speaker recording, MBROLA
voice, or model weights. It replaces the previous Apple Samantha rendering.
The transcript and generated fixture are provided under the repository's MIT
license, to the extent copyright applies.

[eSpeak NG](https://github.com/espeak-ng/espeak-ng/tree/1.52.0) is licensed
GPL-3.0-or-later. It is used as a separate developer tool, and its executable,
libraries and voice data are not redistributed in this repository or the app.
GPLv3 section 2 limits coverage of generated output to output that itself
constitutes a covered work; this WAV contains synthetic speech of our own text.
See the [license](https://github.com/espeak-ng/espeak-ng/blob/1.52.0/COPYING).

Regenerate with `scripts/make_fixtures.sh` from `WisprLocal/App`. Install
eSpeak NG separately if regeneration is needed (`brew install espeak-ng`), or
set `ESPEAK_NG_BIN` to an existing executable. `ESPEAK_NG_PATH` optionally points
to the directory containing `espeak-ng-data`. Running the tests does not require
eSpeak NG.

SwiftPM copies this directory only into the test resource bundle.
`scripts/build_app.sh` excludes test bundles, so the speech fixture is absent
from the packaged WisprLocal app. Historical spike results describe their
original, local Apple-voice benchmark recordings; this replacement does not
change or reproduce those measurements.
