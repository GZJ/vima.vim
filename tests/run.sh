#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
exec vim -Nu NONE -i NONE -n -X -es -S "$repo_root/tests/test_vima.vim"
