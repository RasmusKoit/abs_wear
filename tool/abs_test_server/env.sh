# Loads KEY=VALUE lines from a .env file into the environment without
# running it as shell code (passwords may contain $, backticks or spaces).
# Values are literal: one surrounding pair of quotes is removed, nothing
# else (no inline comments, no escapes). `export KEY=...` lines work too.
# Usage: . tool/abs_test_server/env.sh; load_env path/to/.env
load_env() {
  [ -f "$1" ] || { echo "Missing $1 (copy .env.example and fill it in)" >&2; return 1; }
  local line key value
  while IFS= read -r line || [ -n "$line" ]; do
    line=${line%$'\r'}
    line=${line#"${line%%[![:space:]]*}"} # trim leading whitespace
    line=${line#export }
    case "$line" in '' | \#*) continue ;; *=*) ;; *) continue ;; esac
    key=${line%%=*}
    value=${line#*=}
    if [[ ! $key =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]]; then
      echo "Skipping invalid line in $1: $key" >&2
      continue
    fi
    case "$value" in
      \"*\" | \'*\') value=${value:1:${#value}-2} ;;
    esac
    export "$key=$value"
  done < "$1"
}
