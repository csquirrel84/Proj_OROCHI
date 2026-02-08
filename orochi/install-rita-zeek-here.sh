#!/usr/bin/env bash
set -euo pipefail

# This script downloads and installs rita, zeek, and all dependencies on the current system

export RITA_VERSION="v5.1.1"
export zeek_release='latest'
export PATH="$PATH:/usr/local/bin/"
echo 'export PATH=$PATH:/usr/local/bin/' | sudo tee -a /etc/profile.d/localpath.sh

SUDO=""
if [[ "$EUID" -ne 0 ]]; then
	SUDO="/usr/bin/sudo "
fi

$SUDO mkdir -p /usr/local/bin/

echo "==== Installing rita $RITA_VERSION ====" >&2
cd
wget https://github.com/activecm/rita/releases/download/${RITA_VERSION}/rita-${RITA_VERSION}.tar.gz
tar -xzvf rita-${RITA_VERSION}.tar.gz
cd rita-${RITA_VERSION}-installer

# Patch installer to support Ubuntu 25
sed -i "s/'22', '24'/'22', '24', '25'/" install_pre.yml

# Run installer non-interactively
yes | ./install_rita.sh localhost || true
rita help

echo "==== Installing zeek $zeek_release ====" >&2
$SUDO wget -O /usr/local/bin/zeek https://raw.githubusercontent.com/activecm/docker-zeek/master/zeek
$SUDO chmod +x /usr/local/bin/zeek
/usr/local/bin/zeek pull
sleep 2
/usr/local/bin/zeek stop
echo "Please run 'zeek start' if you want to start zeek running in the background." >&2
echo 'If your system has trouble locating either zeek or rita we recommend logging out and logging back in.' >&2