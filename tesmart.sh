#!/usr/bin/env bash

# https://buytesmart.com/pages/support-manuals

TESMART_HOST=${TESMART_HOST:-192.168.1.10}
TESMART_PORT=${TESMART_PORT:-5000}

usage() {
  echo "Usage: $(basename "$0") ACTION [ARGS]"
  echo -e "\nAvailable ACTIONS:"
  echo "  g, get-input       Get current input ID"
  echo "  s, switch-input    Set the current input ID"
  echo "  m, mute            Mute buzzer"
  echo "  u, unmute          Unmute buzzer"
  echo "  l, led-timeout     Set LED timeout"
  echo "  n, nw-info         Get the current network config"
  echo "  e, exec            Send arbitrary HEX command to the host"
}

send_cmd() {
  if [[ -n "$DEBUG" ]]
  then
    echo "Sending \"$*\" to $TESMART_HOST:$TESMART_PORT" >&2
  fi

  echo -ne "$@" | nc -n "$TESMART_HOST" "$TESMART_PORT"
}

send_cmd_retry() {
  local retries=10
  local try=0
  local raw
  local res
  local printable

  while true
  do
    case "$1" in
      -r|--retries)
        retries="$2"
        shift 2
        ;;
      -R|--raw)
        raw=1
        shift
        ;;
      -e|--expected)
        expected="$2"
        shift 2
        ;;
      *)
        break
        ;;
    esac
  done

  while [[ "$try" -lt "$retries" ]]
  do
    try=$(( try + 1 ))
    res="$(send_cmd "$@" | tr -d '\0')"

    if [[ -n "$DEBUG" ]]
    then
      {
        echo "Raw output: $(cat -vE <<< "$res")"
        echo "Printable output: \"$(tr -dc '[:print:]' <<< "$res" | cat -vE)\""
      } >&2
    fi

    if [[ -n "$res" ]]
    then
      if [[ -z "$raw" ]]
      then
        printable="$(tr -dc '[:print:]' <<< "$res")"
        if [[ -z "$printable" ]]
        then
          continue
        fi

        if [[ -n "$expected" ]] && ! grep -q "$expected" <<< "$printable"
        then
          continue
        fi
      else
        if [[ -n "$expected" ]] && ! hexdump -C <<< "$res" | grep -q "$expected"
        then
          continue
        fi
      fi

      if [[ -n "$DEBUG" ]]
      then
        {
          echo "Got a valid answer after $try try(-ies): \"$res\""
        } >&2
      fi
      echo "$res"
      return
    fi
    sleep 0.2
  done

  return 1
}

set_buzzer() {
  local cmd

  case "$1" in
    off|mute)
      cmd="\xaa\xbb\x03\x02\x00\xee"
      ;;
    *)
      cmd="\xaa\xbb\x03\x02\x01\xee"
      ;;
  esac

  send_cmd "$cmd"
}

mute_buzzer() {
  set_buzzer off
}

unmute_buzzer() {
  set_buzzer on
}

switch_input() {
  send_cmd "\xaa\xbb\x03\x01\x0${1}\xee"
}

set_input_detection() {
  local cmd

  case "$1" in
    off|disable)
      cmd="\xaa\xbb\x03\x81\x00\xee"
      ;;
    *)  # on|enable
      cmd="\xaa\xbb\x03\x81\x01\xee"
      ;;
  esac

  send_cmd "$cmd"
}

set_led_timeout() {
  local cmd

  case "$1" in
    off|disable|never)
      cmd="\xaa\xbb\x03\x03\x00\xee"
      ;;
    10|10s|10-seconds)
      cmd="\xaa\xbb\x03\x03\x0a\xee"
      ;;
    30|30s|30-seconds)
      cmd="\xaa\xbb\x03\x03\x1e\xee"
      ;;
    *)
      echo "❌ Invalid time. It's either 10s, 30s or never" >&2
      return 2
      ;;
  esac

  send_cmd "$cmd"
}

get_current_input() {
  local dec
  local hex
  local input_id
  local res

  res="$(send_cmd_retry -R -e "aa bb 03 11" "\xaa\xbb\x03\x10\x00\xee")"
  hex="$(echo -en "$res" | hexdump -C | awk '/^00000000/ {print $(NF - 2)}')"
  # The next line does not get parsed correctly
  # dec="$(( 16#${hex} ))"
  dec=$(bc <<< "ibase=16; ${hex}")

  if [[ -n "$DEBUG" ]]
  then
    { # DEBUG
      echo -n "$ hexdump -C -> "
      echo -en "$res" | hexdump -C | sed -nr 's/00000000\s+(.+)\s+\|.+\|/\1/p'
      echo "             -> HEX=${hex}"
      echo "             -> DEC=${dec}"
    } >&2
  fi

  if [[ -z "$dec" ]]
  then
    echo "❌ Unable to determine input ID" >&2
    return 4
  fi

  case "$dec" in
    17)
      input_id="1"
      ;;
    *)
      input_id="$(( dec + 1 ))"
      ;;
  esac

  echo "$input_id"
}

sanitize_ip() {
  sed 's/\.0\{1,2\}/\./g' | \
    sed 's/^0\{1,2\}//'
}

get_network_info() {
  local query="$1"
  local res

  res="$(send_cmd_retry -e "${query}:" "${query}?;")"
  sed -nr "s/${query}:(.+);/\1/p" <<< "$res"
}

get_ip() {
  get_network_info "IP" | \
    sanitize_ip
}

get_port() {
  get_network_info "PT" | \
    sed 's/^0\{1,2\}//'
}

get_gateway() {
  get_network_info "GW" | \
    sanitize_ip
}

get_netmask() {
  get_network_info "MA" | \
    sanitize_ip
}

valid_ip() {
  [[ "$1" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]
}

set_ip() {
  local ip="$1"

  if ! valid_ip "$ip"
  then
    echo "❌ $ip in not a valid IP address." >&2
    return 2
  fi

  send_cmd_retry -e OK "IP: $ip;"

  if [[ "$(get_ip)" == "$ip" ]]
  then
    echo "✅ Set ip to $ip"
  else
    echo "❌ Failed to set ip to $ip" >&2
    return 3
  fi
}

set_port() {
  local port="$1"

  if ! [[ "$port" =~ ^[0-9]+$ ]] || \
       [[ "$port" -lt 0 ]] || \
       [[ "$port" -gt 65535 ]]
  then
    echo "❌ $port in not a valid port number." >&2
    return 2
  fi

  send_cmd_retry -e OK "PT: $port;"

  if [[ "$(get_port)" == "$port" ]]
  then
    echo "✅ Port updated to $port"
  else
    echo "❌ Failed to set port to $port" >&2
    return 3
  fi
}

set_netmask() {
  local netmask="$1"

  if ! valid_ip "$netmask"
  then
    echo "❌ $netmask in not a valid netmask." >&2
    return 2
  fi

  send_cmd_retry -e OK "MA: $netmask;"

  if [[ "$(get_netmask)" == "$netmask" ]]
  then
    echo "✅ Netmask updated to $netmask"
  else
    echo "❌ Failed to set netmask to $netmask" >&2
    return 3
  fi
}

set_gateway() {
  local gateway="$1"

  if ! valid_ip "$gateway"
  then
    echo "❌ $gateway in not a valid gateway." >&2
    return 2
  fi

  send_cmd_retry -e OK "GW: $gateway;"

  if [[ "$(get_gateway)" == "$gateway" ]]
  then
    echo "✅ Gateway updated to $gateway"
  else
    echo "❌ Failed to set gateway to $gateway" >&2
    return 3
  fi
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]
then
  while true
  do
    case "$1" in
      --host|-H)
        TESMART_HOST="$2"
        shift 2
        ;;
      --port|-p)
        TESMART_PORT="$2"
        shift 2
        ;;
      --debug|-d|-D)
        DEBUG=1
        shift
        ;;
      *)
        break
        ;;
    esac
  done

  case "$1" in
    help|--help|-h|h)
      usage
      exit 0
      ;;
    mute|m)
      mute_buzzer
      ;;
    unmute|u)
      unmute_buzzer
      ;;
    sound|beep|b)
      if [[ -z "$2" ]]
      then
        echo "❌ Missing arg. Allowed values: on|off" >&2
        exit 2
      fi
      set_buzzer "$2"
      ;;
    led|led-timeout|lights|light|l)
      if [[ -z "$2" ]]
      then
        echo "❌ Missing arg. Allowed values: 10|30|never" >&2
        exit 2
      fi
      set_led_timeout "$2"
      ;;
    input-detection|detection|d)
      if [[ -z "$2" ]]
      then
        echo "❌ Missing arg. Allowed values: on|off" >&2
        exit 2
      fi
      set_input_detection "$2"
      ;;
    switch-input|switch|sw|s)
      input_id="$2"

      if [[ -z "$input_id" ]] || [[ ! "$input_id" =~ ^[0-9]+$ ]]
      then
        echo "❌ Missing or invalid input ID. Allowed values: 1-16" >&2
        exit 2
      fi

      switch_input "$input_id" >/dev/null

      current_input="$(get_current_input)"

      if [[ "$input_id" == "$current_input" ]]
      then
        echo "✔️ Switched to input $input_id"
      else
        echo "❌ Failed switching to $input_id. Current input: $current_input" >&2
        exit 4
      fi
      ;;
    get|get-input|g|state)
      # shellcheck disable=2119
      input="$(get_current_input)"

      if [[ -z "$input" ]]
      then
        echo "❌ Failed to determine current input." >&2
        exit 4
      fi

      echo "📺 Current input: $input"
      ;;
    get-network-info|network-info|nw-info|nw|n)
      ip="$(get_ip)"
      port="$(get_port)"
      netmask="$(get_netmask)"
      gateway="$(get_gateway)"
      echo "IP:      $ip"
      echo "Port:    $port"
      echo "Netmask: $netmask"
      echo "Gateway: $gateway"
      ;;
    get-ip|ip|i)
      get_ip
      ;;
    get-port|port|p)
      get_port
      ;;
    get-netmask|netmask|nm|ma|mask)
      get_netmask
      ;;
    get-gateway|gw)
      get_gateway
      ;;
    set-ip|sip|si)
      set_ip "$2"
      ;;
    set-port|sp)
      set_port "$2"
      ;;
    set-netmask|snetmask|snm)
      set_netmask "$2"
      ;;
    set-gateway|sgateway|sgw)
      set_gateway "$2"
      ;;
    command|cmd|exec|eval|e|c)
      send_cmd "$@"
      ;;
    *)
      echo "❌ Unknown command: $1" >&2
      usage >&2
      exit 2
      ;;
  esac
fi
