#!/usr/bin/env bash
# Builds what goes to PyPI into dist/: the sdist, a universal2 macOS wheel,
# and manylinux2014 wheels for x86_64 and aarch64, built from the sdist in
# Docker. Run ../ext/build.sh first (it needs Spinel; this does not).
#
#   ./build_dists.sh            # then: uv publish dist/*
set -euo pipefail
cd "$(dirname "$0")"

[ -f csrc/build_flags.txt ] || { echo "csrc/ is missing: run ../ext/build.sh first" >&2; exit 1; }
rm -rf dist build superwings_spinel.egg-info
uv build --sdist . -o dist
sdist=$(ls dist/superwings_spinel-*.tar.gz)

if [ "$(uname)" = Darwin ]; then
  ARCHFLAGS="-arch arm64 -arch x86_64" _PYTHON_HOST_PLATFORM=macosx-11.0-universal2 \
    uv build --wheel "$sdist" -o dist
fi

for arch in x86_64 aarch64; do
  platform=linux/$([ $arch = x86_64 ] && echo amd64 || echo arm64)
  docker run --rm --platform "$platform" -v "$PWD/dist:/dist" "quay.io/pypa/manylinux2014_$arch" bash -euc "
    /opt/python/cp312-cp312/bin/pip wheel -q --no-deps /dist/$(basename "$sdist") -w /tmp/wheel
    auditwheel repair -w /dist /tmp/wheel/*.whl"
done
ls -l dist
