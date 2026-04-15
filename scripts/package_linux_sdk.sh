#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage:
  scripts/package_linux_sdk.sh <source-root> <build-dir> <output-dir>

Example:
  scripts/package_linux_sdk.sh \
    /tmp/crashpad-work/crashpad \
    /tmp/crashpad-work/crashpad/out/Release \
    /tmp/dist/crashpad-sdk-linux-x86_64
EOF
}

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
  usage
  exit 0
fi

if [[ $# -ne 3 ]]; then
  usage >&2
  exit 2
fi

SOURCE_ROOT="$(cd "$1" && pwd)"
BUILD_DIR="$(cd "$2" && pwd)"
OUTPUT_DIR="$3"

if [[ ! -f "${SOURCE_ROOT}/package.h" ]]; then
  echo "[ERROR] ${SOURCE_ROOT} does not look like a Crashpad source checkout" >&2
  exit 1
fi

if [[ ! -x "${BUILD_DIR}/crashpad_handler" ]]; then
  echo "[ERROR] missing built handler: ${BUILD_DIR}/crashpad_handler" >&2
  exit 1
fi

if [[ ! -d "${BUILD_DIR}/obj" ]]; then
  echo "[ERROR] missing build obj directory: ${BUILD_DIR}/obj" >&2
  exit 1
fi

rm -rf "${OUTPUT_DIR}"
mkdir -p "${OUTPUT_DIR}/include" "${OUTPUT_DIR}/lib" "${OUTPUT_DIR}/bin"

copy_headers() {
  local src_rel="$1"
  local dst_rel="$2"
  mkdir -p "${OUTPUT_DIR}/include/${dst_rel}"
  find "${SOURCE_ROOT}/${src_rel}" -type f \
    \( -name '*.h' -o -name '*.hpp' -o -name '*.inc' \) \
    -print0 | while IFS= read -r -d '' path; do
      local rel_path="${path#${SOURCE_ROOT}/${src_rel}/}"
      mkdir -p "${OUTPUT_DIR}/include/${dst_rel}/$(dirname "${rel_path}")"
      install -m 0644 "${path}" "${OUTPUT_DIR}/include/${dst_rel}/${rel_path}"
    done
}

# Public Crashpad headers.
copy_headers "client" "client"
copy_headers "compat" "compat"
copy_headers "handler" "handler"
copy_headers "minidump" "minidump"
copy_headers "snapshot" "snapshot"
copy_headers "tools" "tools"
copy_headers "util" "util"

# Public mini_chromium headers required transitively by Crashpad's client API.
copy_headers "third_party/mini_chromium/mini_chromium/base" "base"
copy_headers "third_party/mini_chromium/mini_chromium/build" "build"

# Linux-only transitive include roots.
copy_headers "third_party/lss" "third_party/lss"
copy_headers "third_party/zlib" "third_party/zlib"

install -m 0644 "${SOURCE_ROOT}/package.h" "${OUTPUT_DIR}/include/package.h"
install -m 0755 "${BUILD_DIR}/crashpad_handler" "${OUTPUT_DIR}/bin/crashpad_handler"

manifest="${OUTPUT_DIR}/manifest.txt"
: > "${manifest}"

copy_archive() {
  local src="$1"
  local dst_name="$2"
  install -m 0644 "${src}" "${OUTPUT_DIR}/lib/${dst_name}"
  printf '%s <- %s\n' "${dst_name}" "${src#${BUILD_DIR}/}" >> "${manifest}"
}

archive_name_for() {
  local rel="$1"
  local base
  base="$(basename "${rel}")"
  local stem="${base#lib}"
  stem="${stem%.a}"

  case "${rel}" in
    third_party/mini_chromium/mini_chromium/base/libbase.a)
      printf 'libbase.a'
      return
      ;;
    third_party/mini_chromium/mini_chromium/*/*.a)
      local dir="${rel%/*}"
      local label="${dir#third_party/mini_chromium/mini_chromium/}"
      label="${label//\//_}"
      if [[ "${stem}" == "${label##*_}" ]]; then
        printf 'libmini_chromium_%s.a' "${label}"
      else
        printf 'libmini_chromium_%s_%s.a' "${label}" "${stem}"
      fi
      return
      ;;
    client/*.a|compat/*.a|handler/*.a|minidump/*.a|snapshot/*.a|tools/*.a|util/*.a|util/*/*.a)
      local dir="${rel%/*}"
      local label="${dir//\//_}"
      if [[ "${stem}" == "${label##*_}" ]]; then
        printf 'libcrashpad_%s.a' "${label}"
      else
        printf 'libcrashpad_%s_%s.a' "${label}" "${stem}"
      fi
      return
      ;;
  esac

  return 1
}

while IFS= read -r -d '' archive; do
  rel="${archive#${BUILD_DIR}/obj/}"
  if dst_name="$(archive_name_for "${rel}")"; then
    copy_archive "${archive}" "${dst_name}"
  fi
done < <(find "${BUILD_DIR}/obj" -type f -name '*.a' -print0 | sort -z)

cat > "${OUTPUT_DIR}/sdk-metadata.txt" <<EOF
source_root=${SOURCE_ROOT}
build_dir=${BUILD_DIR}
required_system_libs=-lcurl -lz -ldl -lpthread
notes=Linux standalone Crashpad uses system libcurl and zlib in addition to packaged static archives.
EOF

echo "[INFO] wrote SDK to ${OUTPUT_DIR}"
