# Shared release version. Source after setting APP_DIR.
RELEASE_VERSION="$(cat "$APP_DIR/VERSION")"
if [[ ! "$RELEASE_VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  echo "ERROR: VERSION must contain a numeric major.minor.patch version" >&2
  exit 1
fi
if [ -n "${VERSION:-}" ] && [ "$VERSION" != "$RELEASE_VERSION" ]; then
  echo "WARNING: VERSION=$VERSION overrides VERSION file ($RELEASE_VERSION) for an experimental build" >&2
fi
VERSION="${VERSION:-$RELEASE_VERSION}"
