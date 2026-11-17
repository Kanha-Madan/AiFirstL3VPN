#!/usr/bin/env bash
# Shared semantic classifier for testbed *_env fields.

cxta_env_class() {
  local key="$1"
  case "${key}" in
    url_env|host_env|port_env) echo endpoint ;;
    name_env) echo identity ;;
    username_env|user_env|password_env) echo credential ;;
    *)
      if [[ "${key}" =~ (password|secret|token|passwd) ]]; then
        echo disposable-secret
      else
        echo passthrough
      fi
      ;;
  esac
}

cxta_env_pairs() {
  grep -hoE '^[[:space:]]*[A-Za-z0-9_]+_env:[[:space:]]*[A-Z][A-Z0-9_]*' "$@" 2>/dev/null |
    sed -E 's/^[[:space:]]*([A-Za-z0-9_]+_env):[[:space:]]*([A-Z][A-Z0-9_]*)[[:space:]]*$/\1 \2/' |
    sort -u
}

cxta_env_plan() {
  local key var class
  while read -r key var; do
    [[ -z "${key:-}" || -z "${var:-}" ]] && continue
    class="$(cxta_env_class "${key}")"
    case "${class}:${key}" in
      endpoint:url_env) echo "${class}|${key}|${var}|derived-url" ;;
      endpoint:host_env) echo "${class}|${key}|${var}|derived-host" ;;
      endpoint:port_env) echo "${class}|${key}|${var}|derived-port" ;;
      identity:*) echo "${class}|${key}|${var}|testbed-default" ;;
      credential:*) echo "${class}|${key}|${var}|required" ;;
      disposable-secret:*) echo "${class}|${key}|${var}|random-if-unset" ;;
      *) echo "${class}|${key}|${var}|forward-if-set" ;;
    esac
  done
}
