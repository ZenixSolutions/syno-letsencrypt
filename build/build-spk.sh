#!/usr/bin/env bash
#
# build-spk.sh — assemble a DSM 7 .spk.
#
# No Synology toolchain is involved. pkgscripts-ng exists to cross-compile C in
# a chroot and to sign packages, and neither applies here: the payload is shell
# plus two static Go/C binaries, and package signing was removed in DSM 7.
# An .spk is an uncompressed tar with package.tgz as its first member.
#
# Usage:
#   build/build-spk.sh [--arch x86_64|armv8|armv7] [--version 1.0.0-1] [--all]
#
set -euo pipefail

REPO_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
readonly REPO_ROOT
readonly DIST="${REPO_ROOT}/dist"
readonly VENDOR="${REPO_ROOT}/vendor"

# Synology arch family -> (lego GOARCH suffix, jq release suffix)
declare -A LEGO_ARCH=(  [x86_64]=amd64      [armv8]=arm64      [armv7]=armv7 )
declare -A JQ_ARCH=(    [x86_64]=linux-amd64 [armv8]=linux-arm64 [armv7]=linux-armhf )

LEGO_VERSION="${LEGO_VERSION:-4.35.2}"
JQ_VERSION="${JQ_VERSION:-1.8.1}"

log() { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
die() { printf '\033[1;31mError:\033[0m %s\n' "$*" >&2; exit 1; }

# ---------------------------------------------------------------------------
# Dependencies are vendored rather than downloaded on the NAS at install time.
# Downloading during postinst would mean install fails on an air-gapped or
# proxied network, and would make the shipped artifact unauditable — the .spk
# a user inspects would not be the code that ends up running.
# ---------------------------------------------------------------------------
fetch_lego() {
    local arch="$1" goarch="${LEGO_ARCH[$1]}"
    local out="${VENDOR}/lego-${arch}"
    [ -f "${out}" ] && { log "lego (${arch}) already vendored"; return; }

    log "Fetching lego ${LEGO_VERSION} for ${arch}"
    mkdir -p "${VENDOR}"
    curl -fsSL \
        "https://github.com/go-acme/lego/releases/download/v${LEGO_VERSION}/lego_v${LEGO_VERSION}_linux_${goarch}.tar.gz" \
        | tar -xzO lego > "${out}"
    chmod 755 "${out}"
}

fetch_jq() {
    local arch="$1" jqarch="${JQ_ARCH[$1]}"
    local out="${VENDOR}/jq-${arch}"
    [ -f "${out}" ] && { log "jq (${arch}) already vendored"; return; }

    # DSM does not ship jq. Bundling it is what makes the JSON handling in
    # cloudflare.sh and dsm.sh safe to rely on.
    log "Fetching jq ${JQ_VERSION} for ${arch}"
    mkdir -p "${VENDOR}"
    curl -fsSL -o "${out}" \
        "https://github.com/jqlang/jq/releases/download/jq-${JQ_VERSION}/jq-${jqarch}"
    chmod 755 "${out}"
}

# Cleanup is an EXIT trap over a stack of temp dirs rather than a per-function
# RETURN trap: bash RETURN traps are global, not function-scoped, so a
# `trap ... RETURN` set here also fires when main() returns — with the local
# variable already out of scope and `set -u` active.
_TMPDIRS=()
cleanup_tmpdirs() { [ ${#_TMPDIRS[@]} -eq 0 ] || rm -rf "${_TMPDIRS[@]}"; }
trap cleanup_tmpdirs EXIT

build_one() {
    local arch="$1" version="$2"
    local work; work="$(mktemp -d)"
    _TMPDIRS+=("${work}")

    log "Building ${arch} (version ${version})"
    fetch_lego "${arch}"
    fetch_jq   "${arch}"

    # ---- payload -> package.tgz -> $SYNOPKG_PKGDEST ----
    local payload="${work}/payload"
    mkdir -p "${payload}/bin" "${payload}/lib"

    install -m 755 "${REPO_ROOT}/src/bin/syno-letsencrypt" "${payload}/bin/"
    install -m 755 "${VENDOR}/lego-${arch}"                "${payload}/bin/lego"
    install -m 755 "${VENDOR}/jq-${arch}"                  "${payload}/bin/jq"
    install -m 644 "${REPO_ROOT}"/src/lib/*.sh             "${payload}/lib/"

    tar czf "${work}/package.tgz" -C "${payload}" --owner=root --group=root .

    # ---- metadata ----
    local checksum changelog
    checksum="$(md5sum "${work}/package.tgz" | cut -d' ' -f1)"
    changelog="$(sed -n '/^## /{s/^## //;p;q;}' "${REPO_ROOT}/CHANGELOG.md" 2>/dev/null || echo "See GitHub releases.")"

    sed -e "s|@VERSION@|${version}|g" \
        -e "s|@ARCH@|${arch}|g" \
        -e "s|@CHECKSUM@|${checksum}|g" \
        -e "s|@CHANGELOG@|${changelog//|/\\|}|g" \
        "${REPO_ROOT}/spk/INFO.in" > "${work}/INFO"

    cp -r "${REPO_ROOT}/spk/scripts" "${REPO_ROOT}/spk/conf" \
          "${REPO_ROOT}/spk/WIZARD_UIFILES" "${work}/"
    chmod 755 "${work}"/scripts/*
    # Wizard JSON must be readable but not executable; the *.sh dynamic-wizard
    # variants would need 755, and we ship none.
    chmod 644 "${work}"/WIZARD_UIFILES/*

    local -a icons=()
    for icon in PACKAGE_ICON.PNG PACKAGE_ICON_256.PNG; do
        if [ -f "${REPO_ROOT}/spk/${icon}" ]; then
            cp "${REPO_ROOT}/spk/${icon}" "${work}/"
            icons+=("${icon}")
        fi
    done

    # ---- assemble ----
    # package.tgz MUST be the first member of the archive.
    mkdir -p "${DIST}"
    local spk="${DIST}/syno-letsencrypt-${version}-${arch}.spk"
    ( cd "${work}" && tar cf "${spk}" --owner=root --group=root \
        package.tgz INFO scripts conf WIZARD_UIFILES "${icons[@]}" )

    ( cd "${DIST}" && sha256sum "$(basename "${spk}")" > "$(basename "${spk}").sha256" )
    log "Built ${spk}"
}

# ---------------------------------------------------------------------------

main() {
    local arch="" version="" all=false

    while [ $# -gt 0 ]; do
        case "$1" in
            --arch)    arch="$2"; shift 2 ;;
            --version) version="$2"; shift 2 ;;
            --all)     all=true; shift ;;
            *) die "Unknown argument: $1" ;;
        esac
    done

    [ -n "${version}" ] || version="$(sed -n 's/^## \[\?\([0-9][^]# ]*\)\]\?.*/\1/p' \
        "${REPO_ROOT}/CHANGELOG.md" 2>/dev/null | head -n1)-1"
    [ -n "${version}" ] || die "Could not determine version; pass --version."

    if [ "${all}" = true ]; then
        for a in "${!LEGO_ARCH[@]}"; do build_one "${a}" "${version}"; done
    else
        [ -n "${arch}" ] || die "Pass --arch <x86_64|armv8|armv7> or --all."
        [ -n "${LEGO_ARCH[${arch}]:-}" ] || die "Unsupported arch: ${arch}"
        build_one "${arch}" "${version}"
    fi
}

main "$@"
