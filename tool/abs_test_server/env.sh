# Loads KEY=VALUE lines from a .env file into the environment without
# running it as shell code (passwords may contain $, backticks or spaces).
# Usage: . tool/abs_test_server/env.sh; load_env path/to/.env
load_env() {
  [ -f "$1" ] || { echo "Missing $1 (copy .env.example and fill it in)" >&2; return 1; }
  local line key
  while IFS= read -r line || [ -n "$line" ]; do
    line=${line%$'\r'}
    case "$line" in '' | \#*) continue ;; esac
    key=${line%%=*}
    export "$key=${line#*=}"
  done < "$1"
}
