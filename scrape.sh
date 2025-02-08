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

  echo "Fetching product ${productId}..."
  [[ -s "${DATA_DIR}/${productId}.html" && ! "${force}" ]] || {
     echo "  * fetching HTML from ${BASE_URL}"
     curl -sS "${BASE_URL}/${LANG_ID}/p/${productId}" >| "${DATA_DIR}/${productId}.html"
  }

  [[ -s "${DATA_DIR}/${productId}.json" && ! "${force}" ]] || {
     echo "  * extracting JSON data from HTML"
     sed -Ene 's/var +GarminAppBootstrap *= *(\{.*\});/\1/p' \
       "${DATA_DIR}/${productId}.html" >| "${DATA_DIR}/${productId}.json"
  }

  # Process each SKU.
  while IFS= read -d '' -r sku; do
    echo "  * extracting SKU $productId-$sku"
    #jq -r '.skus[].tabs.specsTab.content'
    jq --arg sku "${sku}" '.skus[$sku]' "${DATA_DIR}/${productId}.json" >| "${DATA_DIR}/${productId}-${sku}.json"
    jq --arg sku "${sku}" --raw-output '.skus[$sku].tabs.specsTab.content' "${DATA_DIR}/${productId}.json" >| \
      "${DATA_DIR}/${productId}-${sku}.specs"

    # Extract all specificiations from the SKU's HTML table, and return as JSON object.
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
	  )" "${DATA_DIR}/${productId}-${sku}.specs") | jq --slurp 'from_entries' > /dev/null
  done < <(jq --raw-output0 --sort-keys '.skus|keys[]' "${DATA_DIR}/${productId}.json")
}

function fetchAllProducts {
  fetchProduct 1057989
  fetchProduct 1228429
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
