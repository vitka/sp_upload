#!/bin/bash
set -euo pipefail

# Configuration
client_id="${MS_GRAPH_CLIENT_ID}"
client_secret="${MS_GRAPH_CLIENT_SECRET}"
tenant_id="${MS_GRAPH_TENANT_ID}"
domain="${MS_GRAPH_DOMAIN}"
site="${MS_GRAPH_SITE}"
drive="${MS_GRAPH_DRIVE:-Documents}"
folder="${MS_GRAPH_FOLDER}"

chunk_size=10485760 # 10 MiB

# Check for required dependencies and credentials
function check_environment() {
  local required_tools=("curl" "head" "jq" "stat" "tail")
  
  for cmd in "${required_tools[@]}"; do
    if ! command -v "$cmd" &>/dev/null; then
      echo "Missing required tool: $cmd"
      exit 1
    fi
  done

  if [[ -z "$client_id" || "$client_id" == "null" ]]; then
    echo "MS_GRAPH_CLIENT_ID is not set"
    exit 1
  fi
  
  if [[ -z "$client_secret" || "$client_secret" == "null" ]]; then
    echo "MS_GRAPH_CLIENT_SECRET is not set"
    exit 1
  fi
  
  if [[ -z "$tenant_id" || "$tenant_id" == "null" ]]; then
    echo "MS_GRAPH_TENANT_ID is not set"
    exit 1
  fi
}

# Parse command line arguments
function parse_arguments() {
  if [[ $# -lt 1 ]]; then
    echo "Usage: $(basename "$0") <file_path> [<file_path> ...]"
    exit 1
  fi
  
  files=()
  
  for file in "$@"; do
    if [[ -f "$file" ]]; then
      files+=("$file")
    else
      echo "Warning: File not found: $file"
    fi
  done
  
  if [[ ${#files[@]} -eq 0 ]]; then
    echo "No valid files to upload"
    exit 1
  fi
}

# Authenticate to Microsoft Graph API
function get_access_token() {
  local response=$(curl -sS --fail -X POST -H "Content-Type: application/x-www-form-urlencoded" \
    -d "client_id=$client_id" \
    -d "scope=https://graph.microsoft.com/.default" \
    -d "client_secret=$client_secret" \
    -d "grant_type=client_credentials" \
    "https://login.microsoftonline.com/$tenant_id/oauth2/v2.0/token")

  local access_token=$(echo "$response" | jq -r '.access_token // empty')

  if [[ -z "$access_token" ]]; then
    echo "Failed to acquire access token" >&2
    echo "$response" >&2
    exit 1
  fi
  echo "$access_token"
}

# Get SharePoint site ID
function get_site_id() {
  local access_token="$1"
  local domain="$2"
  local site="$3"
  local response=$(curl -sSf -H "Authorization: Bearer $access_token" \
    "https://graph.microsoft.com/v1.0/sites/$domain:/sites/$site")

  local site_id=$(echo "$response" | jq -r '.id // empty')
  if [[ -z "$site_id" ]]; then
    echo "Failed to retrieve site ID" >&2
    echo "$response" >&2
    exit 1
  fi
  echo "$site_id"
}

# Get SharePoint drive ID
function get_drive_id() {
  local access_token="$1"
  local site_id="$2"
  local drive="$3"
  local response=$(curl -sS --fail -H "Authorization: Bearer $access_token" \
    "https://graph.microsoft.com/v1.0/sites/$site_id/drives")

  local drive_id=$(echo "$response" | jq -r ".value[] | select(.name==\"$drive\") | .id // empty")
  if [[ -z "$drive_id" ]]; then
    echo "Failed to retrieve drive ID" >&2
    echo "$response" >&2
    exit 1
  fi
  echo "$drive_id"
}

# Upload small file (<4MB) directly
function upload_small_file() {
  local file_path="$1"
  local destination="$2"
  local access_token="$3"
  local drive_id="$4"
  local file_name=$(basename "$file_path")

  local response=$(curl -sS --fail -X PUT -H "Authorization: Bearer $access_token" \
    --data-binary @"$file_path" \
    "https://graph.microsoft.com/v1.0/drives/$drive_id/root:/$destination:/content")

  local web_url=$(echo "$response" | jq -r '.webUrl // empty')
  if [[ -n "$web_url" ]]; then
    echo "[$file_name] uploaded to $web_url"
  else
    echo "[$file_name] failed to upload"
    echo "$response"
    return 1
  fi
}

# Upload large file (>4MB) in chunks using upload session
function upload_large_file() {
  local file_path="$1"
  local destination="$2"
  local access_token="$3"
  local drive_id="$4"
  local file_name=$(basename "$file_path")

  # Create upload session
  local response=$(curl -sS --fail -X POST \
    -H "Authorization: Bearer $access_token" \
    -H "Content-Type: application/json" \
    -d "{\"item\": {\"@microsoft.graph.conflictBehavior\": \"replace\", \"name\": \"$file_name\"}}" \
    "https://graph.microsoft.com/v1.0/drives/$drive_id/root:/$destination:/createUploadSession")

  local upload_url=$(echo "$response" | jq -r '.uploadUrl // empty')

  if [[ -z "$upload_url" ]]; then
    echo "[$file_name] failed to create upload session"
    echo "$response"
    return 1
  fi

  upload_chunks "$upload_url" "$file_path" "$file_name" "$access_token"
}

# Upload file in chunks
function upload_chunks() {
  local upload_url="$1"
  local file_path="$2"
  local file_name="$3"
  local access_token="$4"
  local file_size=$(stat -f "%z" "$file_path")
  
  local offset=0
  local total_chunks=$(( (file_size + chunk_size - 1) / chunk_size ))
  local current_chunk=0

  while [ "$offset" -lt "$file_size" ]; do
    current_chunk=$((current_chunk + 1))
    local end=$((offset + chunk_size - 1))
    if [ "$end" -ge "$file_size" ]; then
      end=$((file_size - 1))
    fi
    
    echo "[$file_name] $((offset * 100 / file_size))%"
    
    # Upload chunk and check for errors in response
    local response=$(upload_chunk "$upload_url" "$file_path" "$offset" "$end" "$file_size" "$access_token")
    if [[ $(echo "$response" | jq -r 'has("error")') == "true" ]]; then
      local error_msg=$(echo "$response" | jq -r '.error.message')
      echo "[$file_name] chunk upload failed: $error_msg"
      return 1
    fi
    
    offset=$((end + 1))
  done

  local web_url=$(echo "$response" | jq -r '.webUrl // empty')
  if [[ -n "$web_url" ]]; then
    echo "[$file_name] uploaded to $web_url"
  else
    echo "[$file_name] failed to upload"
    echo "$response"
    return 1
  fi
}

# Upload a single chunk
function upload_chunk() {
  local upload_url="$1"
  local file_path="$2"
  local offset="$3"
  local end="$4"
  local file_size="$5"
  local access_token="$6"
  local length=$((end - offset + 1))
  
  echo "$(tail -c +$((offset + 1)) "$file_path" | head -c "$length" | \
    curl -sS --fail -X PUT \
      -H "Authorization: Bearer $access_token" \
      -H "Content-Length: $length" \
      -H "Content-Range: bytes $offset-$end/$file_size" \
      --data-binary @- \
      "$upload_url")"
}

# Process single file upload
function process_file() {
  local file_path="$1"
  local access_token="$2"
  local drive_id="$3"
  local file_name=$(basename "$file_path")
  local file_size=$(stat -f "%z" "$file_path")
  
  echo "[$file_name] starting upload..."
  
  if [[ $file_size -le 4194304 ]]; then
    upload_small_file "$file_path" "$folder/$file_name" "$access_token" "$drive_id"
  else
    upload_large_file "$file_path" "$folder/$file_name" "$access_token" "$drive_id"
  fi
}

function upload_files() {
  local access_token="$1"
  local drive_id="$2"
  shift 2
  local files=("$@")
  local pids=()

  for file in "${files[@]}"; do
    # Start upload in background
    process_file "$file" "$access_token" "$drive_id" &
    pids+=($!)
  done
  
  # Wait for remaining uploads to complete
  for pid in "${pids[@]}"; do
    wait $pid 2>/dev/null || true
  done
}

# Main script
check_environment
parse_arguments "$@"

access_token=$(get_access_token)
site_id=$(get_site_id "$access_token" "$domain" "$site")
drive_id=$(get_drive_id "$access_token" "$site_id" "$drive")

upload_files "$access_token" "$drive_id" "${files[@]}"
