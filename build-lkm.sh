#!/usr/bin/env bash

set -o pipefail

# Copyright (C) 2025 AuxXxilium
# This is free software, licensed under the MIT License.
# See /LICENSE for more information.

# Color output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log_info()  { echo -e "${GREEN}[INFO]${NC} $*"; }
log_warn()  { echo -e "${YELLOW}[WARN]${NC} $*"; }
log_error() { echo -e "${RED}[ERROR]${NC} $*"; }
log_debug() { echo -e "${BLUE}[DEBUG]${NC} $*"; }

# Directories
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
TEMP_DIR="${SCRIPT_DIR}/.tmp_build"
RELEASES_DIR="${SCRIPT_DIR}/releases"
BUILD_TEMP="${TEMP_DIR}/build"
STAGING_DIR="${TEMP_DIR}/staging"

# Configuration
VERSION=""
BUILD_ALL=false
INTERACTIVE_MODE=false

# Platform and kernel version definitions
# Format: "platform:kernel_version"
PLATFORMS=(
  "apollolake:4.4.302"
  "broadwell:4.4.302"
  "broadwellnk:4.4.302"
  "broadwellnkv2:4.4.302"
  "broadwellntbap:4.4.302"
  "denverton:4.4.302"
  "epyc7002:5.10.55"
  "geminilake:4.4.302"
  "geminilakenk:5.10.55"
  "purley:4.4.320"
  "r1000:4.4.302"
  "r1000nk:5.10.55"
  "v1000:4.4.302"
  "v1000nk:5.10.55"
)

# Display usage information
show_help() {
  cat << EOF
${BLUE}=== LKM Build Script ===${NC}

${GREEN}Usage:${NC} $0 [OPTIONS]

${GREEN}Options:${NC}
  -v, --version VERSION   DSM/Toolkit version (7.1, 7.2, 7.3)
  -a, --all               Build all versions (prod and dev)
  -h, --help              Show this help message

${GREEN}Examples:${NC}
  $0 -v 7.2               Build 7.2 (prod and dev)
  $0 --version 7.3        Build 7.3 (prod and dev)
  $0 --all                Build all versions
  $0                      Interactive mode

EOF
}

# Parse command-line arguments
parse_args() {
  while [[ $# -gt 0 ]]; do
    case $1 in
      -v|--version)
        VERSION="$2"
        shift 2
        ;;
      -a|--all)
        BUILD_ALL=true
        shift
        ;;
      -h|--help)
        show_help
        exit 0
        ;;
      *)
        log_error "Unknown option: $1"
        show_help
        exit 1
        ;;
    esac
  done
}

# Prompt user for build configuration when no arguments are given
interactive_mode() {
  echo -e "${BLUE}=== LKM Build Configuration ===${NC}"
  echo ""

  if [ -z "$VERSION" ]; then
    echo "Available versions:"
    echo "  1) 7.2"
    echo "  2) 7.3"
    echo "  3) all"
    echo ""
    read -p "Select version (1-3, or enter version number): " VERSION_INPUT

    case "$VERSION_INPUT" in
      1)         VERSION="7.2" ;;
      2)         VERSION="7.3" ;;
      3)         BUILD_ALL=true ;;
      7.[0-9])   VERSION="$VERSION_INPUT" ;;
      *)         log_error "Invalid selection"; exit 1 ;;
    esac

    INTERACTIVE_MODE=true
  fi
}

# Validate that the requested DSM version is supported
validate_inputs() {
  if [[ ! "$VERSION" =~ ^7\.[0-9]$ ]]; then
    log_error "Invalid version: $VERSION"
    exit 1
  fi
}

# Build LKM modules for all platforms using the specified DSM version
build_lkms() {
  local version=$1

  log_info "Starting LKM Build"
  log_info "Version: $version"
  echo ""

  mkdir -p "$RELEASES_DIR"
  mkdir -p "$BUILD_TEMP"

  local SUCCESSFUL=0
  local FAILED=0
  local FAILED_PLATFORMS=()

  local -a platforms=("${PLATFORMS[@]}")

  log_info "Building for ${#platforms[@]} platforms (dev + prod)"
  echo ""

  # Pull Docker image once before the build loop to avoid per-run layer checks
  log_info "Pre-pulling Docker image: auxxxilium/syno-compiler:${version}"
  docker pull "auxxxilium/syno-compiler:${version}"
  echo ""

  # Iterate over each platform and build both dev and prod targets
  for ENTRY in "${platforms[@]}"; do
    local PLATFORM="${ENTRY%%:*}"
    local KERNEL_VER="${ENTRY##*:}"

    for TARGET in dev prod; do
      log_info "Compiling: ${PLATFORM} (kernel ${KERNEL_VER}) - ${TARGET}"

      local PLATFORM_BUILD_DIR="${BUILD_TEMP}/${PLATFORM}-${version}-${TARGET}"
      mkdir -p "$PLATFORM_BUILD_DIR"
      chmod 777 "$PLATFORM_BUILD_DIR"

      # Run the compiler container; image is already present locally from the pre-pull above
      local docker_output
      local docker_exit_code=0
      docker_output=$(docker run --privileged --rm -t \
        -v "${SCRIPT_DIR}":/input \
        -v "${PLATFORM_BUILD_DIR}":/output \
        "auxxxilium/syno-compiler:${version}" \
        compile-lkm "${PLATFORM}" "${TARGET}" 2>&1) || docker_exit_code=$?

      if [ $docker_exit_code -eq 0 ]; then
        echo "$docker_output" | sed 's/^/  /'

        local FILE_KO="${PLATFORM_BUILD_DIR}/redpill.ko"
        local FOUND=0

        if [ -f "${FILE_KO}" ]; then
          mkdir -p "$RELEASES_DIR"
          local OUTPUT_FILE="${RELEASES_DIR}/rp-${PLATFORM}-${version}-${KERNEL_VER}-${TARGET}.ko.gz"

          # Fix ownership/permissions that may be set by the container
          chmod 644 "${FILE_KO}" 2>/dev/null || sudo chmod 644 "${FILE_KO}" 2>/dev/null || true

          log_debug "Compressing ${FILE_KO} -> ${OUTPUT_FILE}"
          if gzip -9 -c "${FILE_KO}" > "${OUTPUT_FILE}"; then
            local SIZE
            SIZE=$(du -h "${OUTPUT_FILE}" | awk '{print $1}')
            log_info "OK Created: ${PLATFORM}-${version}-${KERNEL_VER}-${TARGET} (${SIZE})"
            ((SUCCESSFUL++))
            FOUND=1
          else
            log_error "FAIL Failed to gzip redpill.ko for ${PLATFORM}-${TARGET}"
          fi
        else
          log_warn "WARN ${PLATFORM}/redpill.ko not found at ${FILE_KO}"
        fi

        if [ $FOUND -eq 0 ]; then
          log_error "FAIL No redpill module found for ${PLATFORM}-${TARGET}"
          ((FAILED++))
          FAILED_PLATFORMS+=("$PLATFORM-$TARGET")
        fi
      else
        echo "$docker_output" | sed 's/^/  /'
        log_error "FAIL Docker compilation failed for ${PLATFORM}-${TARGET}"
        ((FAILED++))
        FAILED_PLATFORMS+=("$PLATFORM-$TARGET")
      fi

      # Remove per-platform build directory immediately to conserve disk space
      rm -rf "$PLATFORM_BUILD_DIR"
    done
  done

  echo ""
  local TOTAL_BUILDS=$(( ${#platforms[@]} * 2 ))  # 2 targets (dev + prod) per platform
  log_info "=== Build Summary ==="
  log_info "Successful: $SUCCESSFUL/$TOTAL_BUILDS"
  log_info "Failed:     $FAILED/$TOTAL_BUILDS"

  if [ $FAILED -gt 0 ]; then
    log_warn "Failed builds: ${FAILED_PLATFORMS[*]}"
  fi

  echo ""
  log_info "Output stored in: $RELEASES_DIR"
  echo ""
}

# Remove temporary build directory
cleanup() {
  rm -rf "$TEMP_DIR"
}

# Write a VERSION file and zip the releases directory for distribution
finalize_release() {
  log_info "Finalizing release..."

  echo "$(date '+%y.%m.%d')" > "${RELEASES_DIR}/VERSION"

  local ZIP_NAME="rp-lkms.zip"
  local ZIP_PATH="${SCRIPT_DIR}/${ZIP_NAME}"

  log_info "Creating release archive: ${ZIP_NAME}"
  (cd "$RELEASES_DIR" && cd .. && zip -9 "$ZIP_PATH" releases/* >/dev/null 2>&1)

  if [ -f "$ZIP_PATH" ]; then
    local SIZE
    SIZE=$(du -h "$ZIP_PATH" | awk '{print $1}')
    log_info "OK Successfully created: $ZIP_PATH"
    log_info "   Size: ${SIZE}"
  else
    log_error "Failed to create zip file"
    return 1
  fi
}

# Build all supported DSM versions sequentially
build_all() {
  log_info "Building all versions..."
  echo ""

  for ver in 7.2 7.3; do
    log_info "Starting: Version $ver"
    VERSION="$ver"
    validate_inputs
    build_lkms "$ver"
    log_info "Completed: Version $ver"
    echo ""
    sleep 2
  done

  log_info "All builds completed!"
}

# Entry point
main() {
  echo ""
  log_info "=== LKM Docker Build System ==="
  echo ""

  parse_args "$@"

  # Enter interactive mode if no arguments were provided
  if [ "$BUILD_ALL" = false ] && [ -z "$VERSION" ]; then
    interactive_mode
  fi

  if [ "$BUILD_ALL" = true ]; then
    build_all
    if [ "$INTERACTIVE_MODE" = true ]; then
      finalize_release
    fi
  else
    validate_inputs
    build_lkms "$VERSION"
  fi

  cleanup

  echo ""
  log_info "=== Done ==="
  log_info "Output stored in: $RELEASES_DIR"
  echo ""
}

# Run cleanup on unexpected exit
trap cleanup EXIT

main "$@"
