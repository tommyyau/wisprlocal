# Shared model config for fetch_models.sh / build_app.sh. Source, don't run.
# BUNDLE_MODELS: comma-separated ASR variants (tokens = ASRModelVariant raw values).
# THE single source of truth for what ships (config-driven; changing the bundle is this one line).
# Decision (2026-10-03): Parakeet TDT 0.6B v2 is the DEFAULT model ("v2" = the enum case
# ASRModelVariant.parakeetV2); Parakeet Ultra ("ultra") ships behind the "Noisy room" toggle.
# Both are bundled; the app loads only the active one. No automatic fallback between them.
# Every bundled token needs Licenses/<folder>/LICENSE (build_app.sh refuses otherwise;
# LicenseTests asserts it for this default).
BUNDLE_MODELS="${BUNDLE_MODELS:-v2,ultra}"

# token -> FluidAudio folder name (asserted by ModelSelectionTests.folderNamesMatchScripts)
model_folder() {
  case "$1" in
    ultra) echo "parakeet-ultra" ;;
    v2) echo "parakeet-tdt-0.6b-v2" ;;
    vad) echo "silero-vad" ;;
    *) echo "unknown model token: $1" >&2; return 1 ;;
  esac
}

# Dev model cache: repo-local and gitignored (WisprLocal/App/.models-cache). build_app.sh copies
# from here into Contents/Resources/Models; the installed app loads ONLY from its bundle, so App
# Support holds user data only (dictionary, history, debug recordings).
MODELS_CACHE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/.models-cache"
# Name kept for build_app.sh (reads it as its fetch dir); it now points at the repo-local cache.
APP_SUPPORT_MODELS="$MODELS_CACHE"
# Former cache locations: used only as LOCAL copy sources by fetch_models.sh (never deleted).
OLD_APP_SUPPORT_MODELS="$HOME/Library/Application Support/WisprLocal/Models"
LEGACY_APP_SUPPORT_MODELS="$HOME/Library/Application Support/WisprLite/Models"

# Tokens to install: the ASR variants plus the Silero VAD (always needed).
model_tokens() { echo "${BUNDLE_MODELS//,/ } vad"; }

# Licence folders shipped in Contents/Resources/Licenses besides the model folders.
LICENSE_EXTRA="FluidAudio"

# Pinned Hugging Face revisions for the one-time download (fetch_models.sh → wisprlocal-fetch-models).
# Reverified 2026-10-04 (22 v2, 20 Ultra, 6 VAD files): every file of the bundled
# models matches these commits byte-for-byte (LFS sha256 / git blob sha1 from the HF API
# paths-info endpoint vs the local copies). Bump only after re-verifying.
export WISPRLOCAL_REV_PARAKEET_V2="ee09c569f73759e6d44c9bd16766f477b2b36d39"      # FluidInference/parakeet-tdt-0.6b-v2-coreml
export WISPRLOCAL_REV_PARAKEET_ULTRA="95eaa59a39d4394f047a4dc5cce480388a60d1b6"   # FluidInference/parakeet-ultra-coreml
export WISPRLOCAL_REV_SILERO_VAD="b419383c55c110e2c9271fa6ee0ea83d03c70d96"       # FluidInference/silero-vad-coreml
