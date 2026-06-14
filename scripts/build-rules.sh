#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DIST_DIR="${DIST_DIR:-"$ROOT_DIR/dist"}"
WORK_DIR="${WORK_DIR:-"$ROOT_DIR/tmp"}"
SING_BOX_VERSION="${SING_BOX_VERSION:-v1.13.13}"
GITHUB_REPO="${GITHUB_REPO:-dagve11/sb-rules}"
GITEE_REPO="${GITEE_REPO:-AGZZY11/sb-rules}"

require_cmd() {
    command -v "$1" >/dev/null 2>&1 || {
        echo "missing required command: $1" >&2
        exit 1
    }
}

json_asset_url() {
    local repo="$1"
    local name="$2"
    curl -fsSL "https://api.github.com/repos/$repo/releases/latest" |
        jq -r --arg name "$name" 'first(.assets[] | select(.name == $name) | .browser_download_url) // empty'
}

json_tag_name() {
    local repo="$1"
    curl -fsSL "https://api.github.com/repos/$repo/releases/latest" | jq -r '.tag_name'
}

download() {
    local url="$1"
    local output="$2"
    echo "download: $url"
    curl -fL --retry 3 --retry-delay 2 -o "$output" "$url"
}

sha256_file() {
    sha256sum "$1" | awk '{print $1}'
}

write_asset_manifest_item() {
    local file="$1"
    local tag="$2"
    local format="$3"
    local sha size github_url gitee_url
    sha="$(sha256_file "$DIST_DIR/$file")"
    size="$(wc -c < "$DIST_DIR/$file" | tr -d ' ')"
    github_url="https://github.com/$GITHUB_REPO/releases/latest/download/$file"
    gitee_url="https://gitee.com/$GITEE_REPO/raw/main/dist/$file"

    jq -n \
        --arg tag "$tag" \
        --arg file "$file" \
        --arg format "$format" \
        --arg sha256 "$sha" \
        --arg url "$github_url" \
        --arg cn_url "$gitee_url" \
        --argjson size "$size" \
        '{
          tag: $tag,
          file: $file,
          format: $format,
          size: $size,
          sha256: $sha256,
          url: $url,
          cn_url: $cn_url
        }'
}

main() {
    require_cmd curl
    require_cmd jq
    require_cmd tar
    require_cmd sha256sum

    rm -rf "$DIST_DIR" "$WORK_DIR"
    mkdir -p "$DIST_DIR" "$WORK_DIR"

    local version_no_v="${SING_BOX_VERSION#v}"
    local archive="sing-box-$version_no_v-linux-amd64.tar.gz"
    local sing_box_url="https://github.com/SagerNet/sing-box/releases/download/$SING_BOX_VERSION/$archive"
    local sing_box_archive="$WORK_DIR/$archive"
    download "$sing_box_url" "$sing_box_archive"
    tar -xzf "$sing_box_archive" -C "$WORK_DIR"

    local sing_box
    sing_box="$(find "$WORK_DIR" -type f -name sing-box -perm -111 | head -n 1)"
    if [[ -z "$sing_box" ]]; then
        echo "failed to locate sing-box binary in $sing_box_archive" >&2
        exit 1
    fi

    local geosite_tag geoip_tag geosite_url geoip_url
    geosite_tag="$(json_tag_name SagerNet/sing-geosite)"
    geoip_tag="$(json_tag_name SagerNet/sing-geoip)"
    geosite_url="$(json_asset_url SagerNet/sing-geosite geosite.db)"
    geoip_url="$(json_asset_url SagerNet/sing-geoip geoip.db)"

    download "$geosite_url" "$WORK_DIR/geosite.db"
    download "$geoip_url" "$WORK_DIR/geoip.db"

    "$sing_box" geosite -f "$WORK_DIR/geosite.db" export cn -o "$DIST_DIR/geosite-cn.json"
    "$sing_box" geoip -f "$WORK_DIR/geoip.db" export cn -o "$DIST_DIR/geoip-cn.json"
    "$sing_box" rule-set compile -o "$DIST_DIR/geosite-cn.srs" "$DIST_DIR/geosite-cn.json"
    "$sing_box" rule-set compile -o "$DIST_DIR/geoip-cn.srs" "$DIST_DIR/geoip-cn.json"

    (
        cd "$DIST_DIR"
        sha256sum geosite-cn.json geoip-cn.json geosite-cn.srs geoip-cn.srs > SHA256SUMS
    )

    local generated_at
    generated_at="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"

    jq -n \
        --arg version "$generated_at" \
        --arg generated_at "$generated_at" \
        --arg sing_box_version "$SING_BOX_VERSION" \
        --arg geosite_source "SagerNet/sing-geosite@$geosite_tag" \
        --arg geoip_source "SagerNet/sing-geoip@$geoip_tag" \
        --slurpfile geosite_srs <(write_asset_manifest_item geosite-cn.srs geosite-cn binary) \
        --slurpfile geoip_srs <(write_asset_manifest_item geoip-cn.srs geoip-cn binary) \
        --slurpfile geosite_json <(write_asset_manifest_item geosite-cn.json geosite-cn-source source) \
        --slurpfile geoip_json <(write_asset_manifest_item geoip-cn.json geoip-cn-source source) \
        '{
          version: $version,
          generated_at: $generated_at,
          sing_box_version: $sing_box_version,
          sources: {
            geosite: $geosite_source,
            geoip: $geoip_source
          },
          assets: [
            $geosite_srs[0],
            $geoip_srs[0],
            $geosite_json[0],
            $geoip_json[0]
          ]
        }' > "$DIST_DIR/manifest.json"

    echo "generated assets:"
    ls -lh "$DIST_DIR"
}

main "$@"
