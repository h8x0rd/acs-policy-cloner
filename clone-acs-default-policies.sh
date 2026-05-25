#!/usr/bin/env bash
set -euo pipefail

# Clone RHACS/ACS built-in default policies to custom policies with a suffix.
# Default clone name: "<original policy name>-ABC"
#
# Required environment variables:
#   ROX_ENDPOINT   Example: https://central-stackrox.apps.example.com
#   ROX_API_TOKEN  RHACS API token with policy read/write permissions
#
# Optional environment variables:
#   SUFFIX            Default: -ABC
#   DISABLE_CLONES    Default: true. Set false to create enabled clones.
#   BATCH_SIZE        Default: 25. Lower this if your Central/API/proxy rejects large payloads.
#   ROX_INSECURE      Default: false. Set true to skip TLS certificate validation.
#   DRY_RUN           Default: false. Set true to build payloads but skip import.
#   KEEP_WORKDIR      Default: false. Set true to keep temporary JSON files for inspection.

SUFFIX="${SUFFIX:--ABC}"
DISABLE_CLONES="${DISABLE_CLONES:-true}"
BATCH_SIZE="${BATCH_SIZE:-25}"
ROX_INSECURE="${ROX_INSECURE:-false}"
DRY_RUN="${DRY_RUN:-false}"
KEEP_WORKDIR="${KEEP_WORKDIR:-false}"

: "${ROX_ENDPOINT:?Set ROX_ENDPOINT, for example https://central-stackrox.apps.example.com}"
: "${ROX_API_TOKEN:?Set ROX_API_TOKEN}"

command -v jq >/dev/null 2>&1 || { echo "ERROR: jq is required" >&2; exit 1; }
command -v curl >/dev/null 2>&1 || { echo "ERROR: curl is required" >&2; exit 1; }

if ! [[ "${BATCH_SIZE}" =~ ^[0-9]+$ ]] || [[ "${BATCH_SIZE}" -lt 1 ]]; then
  echo "ERROR: BATCH_SIZE must be a positive integer" >&2
  exit 1
fi

case "${DISABLE_CLONES}" in
  true|false) ;;
  *) echo "ERROR: DISABLE_CLONES must be true or false" >&2; exit 1 ;;
esac

case "${ROX_INSECURE}" in
  true|false) ;;
  *) echo "ERROR: ROX_INSECURE must be true or false" >&2; exit 1 ;;
esac

case "${DRY_RUN}" in
  true|false) ;;
  *) echo "ERROR: DRY_RUN must be true or false" >&2; exit 1 ;;
esac

case "${KEEP_WORKDIR}" in
  true|false) ;;
  *) echo "ERROR: KEEP_WORKDIR must be true or false" >&2; exit 1 ;;
esac

# Remove trailing slash from endpoint so paths join cleanly.
ROX_ENDPOINT="${ROX_ENDPOINT%/}"

WORKDIR="$(mktemp -d -t acs-policy-clone.XXXXXX)"
cleanup() {
  if [[ "${KEEP_WORKDIR}" == "true" || "${DRY_RUN}" == "true" ]]; then
    echo "Temporary files kept at: ${WORKDIR}"
  else
    rm -rf "${WORKDIR}"
  fi
}
trap cleanup EXIT

CURL_OPTS=(
  -fsS
  --retry 3
  --retry-delay 2
  --connect-timeout 10
)

if [[ "${ROX_INSECURE}" == "true" ]]; then
  CURL_OPTS+=(-k)
fi

api_no_body() {
  local method="$1"
  local path="$2"
  local output_file="$3"

  curl "${CURL_OPTS[@]}" \
    -X "${method}" \
    "${ROX_ENDPOINT}${path}" \
    -H "Authorization: Bearer ${ROX_API_TOKEN}" \
    -H "Content-Type: application/json" \
    -o "${output_file}"
}

api_with_body_file() {
  local method="$1"
  local path="$2"
  local body_file="$3"
  local output_file="$4"

  # Use --data-binary @file to avoid Linux argument length limits with large JSON payloads.
  curl "${CURL_OPTS[@]}" \
    -X "${method}" \
    "${ROX_ENDPOINT}${path}" \
    -H "Authorization: Bearer ${ROX_API_TOKEN}" \
    -H "Content-Type: application/json" \
    --data-binary @"${body_file}" \
    -o "${output_file}"
}

print_import_result() {
  local response_file="$1"

  jq -r '
    if (.responses? | type) == "array" then
      .responses[]
      | if (.succeeded // false) then
          "CREATED: \(.policy.name // .name // "unknown")"
        else
          "FAILED: \(.policy.name // .name // "unknown") - \((.errors // []) | map(.message // tostring) | join("; "))"
        end
    else
      .
    end
  ' "${response_file}"
}

import_succeeded() {
  local response_file="$1"

  jq -e '
    if has("allSucceeded") then
      .allSucceeded == true
    elif has("all_succeeded") then
      .all_succeeded == true
    elif (.responses? | type) == "array" then
      all(.responses[]; (.succeeded // false) == true)
    else
      true
    end
  ' "${response_file}" >/dev/null
}

echo "Reading ACS policies from ${ROX_ENDPOINT} ..."
POLICIES_FILE="${WORKDIR}/policies.json"
api_no_body GET /v1/policies "${POLICIES_FILE}"

if ! jq -e '.policies | type == "array"' "${POLICIES_FILE}" >/dev/null; then
  echo "ERROR: Unexpected response from /v1/policies. Expected a JSON object with a policies array." >&2
  echo "Saved response: ${POLICIES_FILE}" >&2
  KEEP_WORKDIR=true
  exit 1
fi

TO_CLONE_FILE="${WORKDIR}/to-clone.json"
jq \
  --arg suffix "${SUFFIX}" \
  '
    [.policies[].name] as $existingNames
    | [
        .policies[]
        | select((.isDefault // .is_default // false) == true)
        | select((.name | endswith($suffix)) | not)
        | (.name + $suffix) as $cloneName
        | select(($existingNames | index($cloneName)) == null)
        | {id: .id, name: .name, cloneName: $cloneName}
      ]
  ' "${POLICIES_FILE}" > "${TO_CLONE_FILE}"

COUNT="$(jq 'length' "${TO_CLONE_FILE}")"

if [[ "${COUNT}" -eq 0 ]]; then
  echo "No default policies need cloning. Existing ${SUFFIX} clones may already exist."
  exit 0
fi

echo "Policies to clone: ${COUNT}"
jq -r '.[] | " - \(.name) -> \(.cloneName)"' "${TO_CLONE_FILE}"
echo

if [[ "${DRY_RUN}" == "true" ]]; then
  echo "DRY_RUN=true: export and import payloads will be generated, but no policies will be imported."
  echo
fi

mapfile -t POLICY_IDS < <(jq -r '.[].id' "${TO_CLONE_FILE}")
TOTAL="${#POLICY_IDS[@]}"
FAILED=false

for ((OFFSET=0; OFFSET<TOTAL; OFFSET+=BATCH_SIZE)); do
  BATCH_NUM=$((OFFSET / BATCH_SIZE + 1))
  BATCH_IDS=("${POLICY_IDS[@]:OFFSET:BATCH_SIZE}")
  BATCH_COUNT="${#BATCH_IDS[@]}"

  echo "Processing batch ${BATCH_NUM}: ${BATCH_COUNT} policy/policies ..."

  EXPORT_BODY_FILE="${WORKDIR}/export-request-${BATCH_NUM}.json"
  EXPORTED_FILE="${WORKDIR}/exported-policies-${BATCH_NUM}.json"
  IMPORT_BODY_FILE="${WORKDIR}/import-request-${BATCH_NUM}.json"
  IMPORT_RESPONSE_FILE="${WORKDIR}/import-response-${BATCH_NUM}.json"

  printf '%s\n' "${BATCH_IDS[@]}" | jq -R -s '{policyIds: (split("\n") | map(select(length > 0)))}' > "${EXPORT_BODY_FILE}"

  api_with_body_file POST /v1/policies/export "${EXPORT_BODY_FILE}" "${EXPORTED_FILE}"

  if ! jq -e '.policies | type == "array"' "${EXPORTED_FILE}" >/dev/null; then
    echo "ERROR: Unexpected response from /v1/policies/export for batch ${BATCH_NUM}." >&2
    echo "Saved response: ${EXPORTED_FILE}" >&2
    KEEP_WORKDIR=true
    FAILED=true
    continue
  fi

  jq \
    --arg suffix "${SUFFIX}" \
    --argjson disabled "${DISABLE_CLONES}" \
    '
      {
        metadata: {
          overwrite: false
        },
        policies: [
          .policies[]
          | .name = (.name + $suffix)
          | .id = ""
          | .disabled = $disabled
          | if has("isDefault") then .isDefault = false else . end
          | if has("is_default") then .is_default = false else . end
          | if has("criteriaLocked") then .criteriaLocked = false else . end
          | if has("criteria_locked") then .criteria_locked = false else . end
          | if has("mitreVectorsLocked") then .mitreVectorsLocked = false else . end
          | if has("mitre_vectors_locked") then .mitre_vectors_locked = false else . end
          | del(
              .lastUpdated,
              .last_updated,
              .SORTName,
              .SORT_name,
              .SORTLifecycleStage,
              .SORT_lifecycleStage,
              .SORTEnforcement,
              .SORT_enforcement,
              .source
            )
        ]
      }
    ' "${EXPORTED_FILE}" > "${IMPORT_BODY_FILE}"

  if [[ "${DRY_RUN}" == "true" ]]; then
    echo "DRY_RUN: import payload saved to ${IMPORT_BODY_FILE}"
    echo
    continue
  fi

  api_with_body_file POST /v1/policies/import "${IMPORT_BODY_FILE}" "${IMPORT_RESPONSE_FILE}"

  print_import_result "${IMPORT_RESPONSE_FILE}"

  if ! import_succeeded "${IMPORT_RESPONSE_FILE}"; then
    FAILED=true
  fi

  echo
 done

if [[ "${DRY_RUN}" == "true" ]]; then
  echo "Dry run complete. No ACS policies were created."
  exit 0
fi

if [[ "${FAILED}" == "true" ]]; then
  echo "One or more batches failed. Re-run with KEEP_WORKDIR=true to inspect payloads and responses." >&2
  exit 1
fi

echo "Done. Created cloned policies with suffix '${SUFFIX}'."
if [[ "${DISABLE_CLONES}" == "true" ]]; then
  echo "The cloned policies were created disabled. Review and enable them in ACS when ready."
fi
