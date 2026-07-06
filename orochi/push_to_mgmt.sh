#!/usr/bin/env bash
set -euo pipefail

usage() {
    echo "Usage: $0 -i <IP> [-u <User>]" >&2
    echo "       $0 <IP> [User]" >&2
    exit 1
}

USER="ubuntu"
IP=""

# Support both `push_to_mgmt.sh <IP> [User]` and `-i/-u` flags.
if [[ "${1:-}" == -* ]]; then
    while getopts "i:u:" opt; do
        case "$opt" in
            i) IP="$OPTARG" ;;
            u) USER="$OPTARG" ;;
            *) usage ;;
        esac
    done
else
    IP="${1:-}"
    USER="${2:-$USER}"
fi

[[ -z "$IP" ]] && usage

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

scp -r "${SCRIPT_DIR}"/* "${USER}@${IP}:~/orochi/"
