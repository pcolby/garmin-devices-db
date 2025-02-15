#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2025 Paul Colby <git@colby.id.au>
# SPDX-License-Identifier: GPL-3.0-or-later

set -o errexit -o noclobber -o nounset -o pipefail

SCRIPT_PATH=$(realpath -e "${BASH_SOURCE[0]}")
SCRIPT_DIR=$(dirname "${SCRIPT_PATH}")

: "${BASE_URL:=https://www.garmin.com}"
: "${LANG_ID:=en-AU}"
: "${DATA_DIR:=$SCRIPT_DIR/$LANG_ID}"

readonly BASE_URL DATA_DIR LANG_ID SCRIPT_DIR SCRIPT_PATH

if [[ "${1:-}" == '--force' ]]; then force=yes; shift; else force=; fi

function fetchProduct {
  local -r productId="${1}"
  echo "Processing product ${productId}..."

  [[ -s "${DATA_DIR}/${productId}.html" && ! "${force}" ]] || {
     local -r url="${BASE_URL}/${LANG_ID}/p/${productId}"
     echo "  * fetching product HTML: ${url}"
     curl -sS "${url}" >| "${DATA_DIR}/${productId}.html"
  }

  [[ -s "${DATA_DIR}/${productId}.json" && ! "${force}" ]] || {
     echo "  * extracting JSON data from HTML"
     sed -Ene 's/var +GarminAppBootstrap *= *(\{.*\});/\1/p' \
       "${DATA_DIR}/${productId}.html" >| "${DATA_DIR}/${productId}.json"
  }

  # Process each SKU.
  while IFS= read -d '' -r sku; do
    echo "  * found Part Number: $sku"
    [[ -s "${DATA_DIR}/${productId}-${sku}-specs.html" && ! "${force}" ]] || {
      echo "  * extracting HTML specs for: ${sku}"
      jq --arg sku "${sku}" --raw-output '.skus[$sku].tabs.specsTab.content' "${DATA_DIR}/${productId}.json" >| \
        "${DATA_DIR}/${productId}-${sku}-specs.html"
    }

    # Extract all specificiations from the SKU's HTML table, and return as JSON object.
    [[ -s "${DATA_DIR}/${productId}-${sku}-specs.json" && ! "${force}" ]] || {
      echo '  * converting HTML specs to JSON'
      while IFS=$'\x1f' read -d '' -r key value; do
        jq --arg key "${key}" --arg value "${value}" --null-input '{ key: $key, value: $value}'
      done < <(awk "$(cat <<-'-'
		BEGIN { RS="<th |</td>" }
		match($0, /[^>]*>(.*)<\/th>.*<td( *.*class="yes")?>(.*)/, parts) {
		  if (parts[2]) {
		    printf "%s\x1fyes\0",parts[1]
          } else {
		    printf "%s\x1f%s\0",parts[1],parts[3]
		  }
		}
		-
      )" "${DATA_DIR}/${productId}-${sku}-specs.html") |
        jq --arg 'sku' "${sku}" --slurp '{ sku: $sku, specs: from_entries }' >| \
        "${DATA_DIR}/${productId}-${sku}-specs.json"
    }
  done < <(jq --raw-output0 --sort-keys '.skus|keys[]' "${DATA_DIR}/${productId}.json")

  # Insert the extracted specs back into the original JSON object.
  [[ -s "${DATA_DIR}/${productId}-full.json" && ! "${force}" ]] || {
    if [[ "$(find "${DATA_DIR}" -name "${productId}-*-specs.json" -print -quit)" ]]; then
      echo '  * embedding specs JSON'
      jq --slurp --sort-keys "$(cat <<-'-'
		.[0] * { skus: [.[1:][]|{ key: .sku, value: { specs: .specs } }]|from_entries }
		-
	    )" "${DATA_DIR}/${productId}.json" "${DATA_DIR}/${productId}-"*-specs.json >| \
        "${DATA_DIR}/${productId}-full.json"
    else
      echo '  * copying source JSON'
      jq --sort-keys . "${DATA_DIR}/${productId}.json" >| "${DATA_DIR}/${productId}-full.json"
    fi
  }
}

function fetchAllProducts {
  # Fetch the sitemap.
  [[ -s "${DATA_DIR}/sitemap.xml" && ! "${force}" ]] || {
    echo "Fetching sitemap: ${BASE_URL}/${LANG_ID}/sitemap.xml"
    curl -sS "${BASE_URL}/${LANG_ID}/sitemap.xml" >| "${DATA_DIR}/sitemap.xml"
  }

  # Fetch all productIds in the sitemap.
  local -a productIds=(
    $(tr '<>' '\n' < "${DATA_DIR}/sitemap.xml" | sed -Ene 's|^https://[^/]+/..-../p/([0-9]+)$|\1|p' | sort -n))
  echo "Fetching ${#productIds[@]} products..."
  for productId in "${productIds[@]}"; do
    fetchProduct "${productId}"
  done

  # \todo Fetch all category pages in the sitemap.
}

mkdir -p "${DATA_DIR}" || {
  echo "Failed to create directory: ${DATA_DIR}" >&2
  false
}

[[ $# -gt 0 ]] || fetchAllProducts

while [[ $# -gt 0 ]]; do
  fetchProduct "$1"
  shift
done

# Combine them all.
echo "Combining all products: products-$LANG_ID.json"
jq --slurp --sort-keys '[.[]|{ key: .productId, value: .}]|from_entries' "${DATA_DIR}/"*-full.json >| \
  "$SCRIPT_DIR/products-$LANG_ID.json"
echo 'Done.'
