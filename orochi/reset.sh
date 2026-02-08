#!/bin/bash

# Define the path to the certs folder
CERTS_FOLDER="./certs"
RAPTOR_FOLDER="./velociraptor"
echo "Stopping all running Docker containers..."
docker stop $(docker ps -aq)

echo "Removing all Docker containers..."
docker rm $(docker ps -aq)

echo "Removing all Docker images..."
docker rmi -f $(docker images -q)

echo "Removing all Docker volumes..."
docker volume rm $(docker volume ls -q)

echo "Removing all Docker networks (except default)..."
docker network rm $(docker network ls -q | grep -v "bridge\|host\|none")

echo "Cleaning up unused Docker resources..."
docker system prune -af
docker volume prune -f

# Remove the certs folder if it exists
if [ -d "$CERTS_FOLDER" ]; then
    echo "Removing $CERTS_FOLDER directory..."
    rm -rf "$CERTS_FOLDER"
else
    echo "$CERTS_FOLDER directory does not exist."
fi

# Remove the VELOCIRAPTOR folder if it exists
if [ -d "$RAPTOR_FOLDER" ]; then
    echo "Removing $RAPTOR_FOLDER directory..."
    rm -rf "$RAPTOR_FOLDER"
else
    echo "$RAPTOR_FOLDER directory does not exist."
fi

# Ensure that zeek is removed
sudo dpkg --purge --force-all $(dpkg -l | grep zeek | awk '{print $2}')
if [ -d "/opt/zeek" ]; then
    echo "Removing /opt/zeek & /opt/rita directory..."
    rm -rf /opt/zeek
    rm -rf /opt/rita
else
    echo "/opt/zeek directory does not exist."
fi

clear

echo "Reset complete. Docker environment, /opt/zeek, and certs folder have been cleaned."
