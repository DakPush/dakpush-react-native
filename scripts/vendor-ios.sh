#!/usr/bin/env bash
# Copies the DakPush iOS SDK's Swift sources from a release tag into
# ios/vendor, so the bridge's pod builds them (see ios/vendor/README.md).
#
#   scripts/vendor-ios.sh            # the version in ios/vendor/VERSION
#   scripts/vendor-ios.sh 0.3.0      # another release
#   scripts/vendor-ios.sh --check    # CI: ios/vendor is exactly that tag
#
# DAKPUSH_IOS_SRC=/path/to/dakpush-ios uses a local clone instead of GitHub
# (the tag must exist there).
#
# The only change to the sources: DakPush and DakPushExtension become one
# module here, so the lines importing DakPushExtension are dropped.
set -euo pipefail

cd "$(dirname "$0")/.."
REPO_URL="https://github.com/DakPush/dakpush-ios.git"
VENDOR="ios/vendor"

check=0
version=""
for arg in "$@"; do
  case "$arg" in
    --check) check=1 ;;
    -*) echo "unknown option $arg" >&2; exit 2 ;;
    *) version="$arg" ;;
  esac
done
if [[ -z "$version" ]]; then
  version="$(sed -n 's/^version=//p' "$VENDOR/VERSION")"
fi
[[ -n "$version" ]] || { echo "no version" >&2; exit 2; }

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

if [[ -n "${DAKPUSH_IOS_SRC:-}" ]]; then
  git -C "$DAKPUSH_IOS_SRC" archive --format=tar "refs/tags/$version" Sources LICENSE | tar -x -C "$work"
  commit="$(git -C "$DAKPUSH_IOS_SRC" rev-parse "refs/tags/$version^{commit}")"
else
  git clone --quiet --depth 1 --branch "$version" "$REPO_URL" "$work/repo"
  commit="$(git -C "$work/repo" rev-parse HEAD)"
  mv "$work/repo/Sources" "$work/repo/LICENSE" "$work/"
fi

out="$work/out"
mkdir -p "$out/DakPush" "$out/DakPushExtension"
(cd "$work/Sources/DakPush" && find . -type f \( -name '*.swift' -o -name 'PrivacyInfo.xcprivacy' \) | while read -r f; do
  mkdir -p "$out/DakPush/$(dirname "$f")"
  # One module here: DakPushExtension's types are in it already.
  grep -v -E '^(@_spi\(DakInternal\) )?import DakPushExtension$' "$f" > "$out/DakPush/$f" || true
done)
(cd "$work/Sources/DakPushExtension" && find . -type f \( -name '*.swift' -o -name 'PrivacyInfo.xcprivacy' \) | while read -r f; do
  mkdir -p "$out/DakPushExtension/$(dirname "$f")"
  cp "$f" "$out/DakPushExtension/$f"
done)
cp "$work/LICENSE" "$out/LICENSE"
printf 'version=%s\ncommit=%s\nsource=%s\n' "$version" "$commit" "$REPO_URL" > "$out/VERSION"
cp "$VENDOR/README.md" "$out/README.md" 2>/dev/null || true

if [[ $check -eq 1 ]]; then
  if diff -r "$out" "$VENDOR" > "$work/diff.txt"; then
    echo "ios/vendor is DakPush iOS $version ($commit)"
  else
    cat "$work/diff.txt" >&2
    echo "ios/vendor differs from DakPush iOS $version: run scripts/vendor-ios.sh $version" >&2
    exit 1
  fi
else
  rm -rf "$VENDOR.new"
  cp -R "$out" "$VENDOR.new"
  rm -rf "$VENDOR"
  mv "$VENDOR.new" "$VENDOR"
  echo "ios/vendor is now DakPush iOS $version ($commit)"
fi
