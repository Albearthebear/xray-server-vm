#!/bin/bash
# Custom Tunnel - GCP Deployment Script for Alpine Linux VM
# This script deploys a Custom Tunnel server to Google Cloud Platform

# Configuration
PROJECT_ID=${PROJECT_ID:-"custom-tunnel-project"}
REGION=${REGION:-"europe-west4"}
ZONE=${ZONE:-"europe-west4-a"}
VM_NAME=${VM_NAME:-"custom-tunnel-server"}
MACHINE_TYPE=${MACHINE_TYPE:-"e2-micro"}  # Small VM for 1-2 connections
DISK_SIZE=${DISK_SIZE:-"10GB"}  # Minimal for Alpine

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

echo -e "${GREEN}Custom Tunnel - GCP Deployment Script${NC}"
echo -e "${YELLOW}This script will deploy a custom tunnel server on GCP using Alpine Linux${NC}"
echo

# Check if gcloud is installed
if ! command -v gcloud &> /dev/null; then
    echo -e "${RED}Error: gcloud CLI is not installed${NC}"
    echo "Please install the Google Cloud SDK: https://cloud.google.com/sdk/docs/install"
    exit 1
fi

# Check if user is logged in
if ! gcloud auth list --filter=status:ACTIVE --format="value(account)" &> /dev/null; then
    echo -e "${YELLOW}You need to log in to gcloud:${NC}"
    gcloud auth login
fi

# Set up project
echo -e "${GREEN}Setting up project...${NC}"
if gcloud projects describe "$PROJECT_ID" &> /dev/null; then
    echo "Project $PROJECT_ID already exists"
else
    echo "Creating project $PROJECT_ID..."
    gcloud projects create "$PROJECT_ID"
fi

gcloud config set project "$PROJECT_ID"

# Enable required APIs
echo -e "${GREEN}Enabling required APIs...${NC}"
gcloud services enable compute.googleapis.com

# Create firewall rules
echo -e "${GREEN}Creating firewall rules...${NC}"
if ! gcloud compute firewall-rules describe "allow-tunnel" --project="$PROJECT_ID" &> /dev/null; then
    gcloud compute firewall-rules create "allow-tunnel" \
        --project="$PROJECT_ID" \
        --direction=INGRESS \
        --priority=1000 \
        --network=default \
        --action=ALLOW \
        --rules=tcp:22,tcp:8000-8001 \
        --source-ranges=0.0.0.0/0 \
        --target-tags=tunnel-server
fi

# Create VM instance with Alpine Linux
echo -e "${GREEN}Creating VM instance...${NC}"
if gcloud compute instances describe "$VM_NAME" --zone="$ZONE" &> /dev/null; then
    echo -e "${YELLOW}VM instance $VM_NAME already exists${NC}"
else
    echo "Creating VM instance $VM_NAME..."
    gcloud compute instances create "$VM_NAME" \
        --project="$PROJECT_ID" \
        --zone="$ZONE" \
        --machine-type="$MACHINE_TYPE" \
        --image-project="alpine-linux-gce" \
        --image-family="alpine-3-15" \
        --boot-disk-size="$DISK_SIZE" \
        --tags=tunnel-server \
        --metadata=startup-script-url=gs://gce-public-alpine/alpine-sshd-setup.sh
fi

# Wait for VM to be ready
echo -e "${YELLOW}Waiting for VM to be ready...${NC}"
sleep 30

# Get the external IP
EXTERNAL_IP=$(gcloud compute instances describe "$VM_NAME" --zone="$ZONE" --format='get(networkInterfaces[0].accessConfigs[0].natIP)')
echo -e "${GREEN}VM external IP: $EXTERNAL_IP${NC}"

# Generate and upload the setup script
echo -e "${GREEN}Uploading setup script...${NC}"
# Create a temporary file
TEMP_SCRIPT=$(mktemp)

# Copy the setup script content to the temp file
cat "$(dirname "$0")/setup_vm.sh" > "$TEMP_SCRIPT"

# Transfer the script to the VM
gcloud compute scp "$TEMP_SCRIPT" "root@$VM_NAME:~/setup_vm.sh" --zone="$ZONE"

# Clean up the temp file
rm "$TEMP_SCRIPT"

# Execute the setup script
echo -e "${GREEN}Executing setup script on VM...${NC}"
gcloud compute ssh "root@$VM_NAME" --zone="$ZONE" -- "chmod +x ~/setup_vm.sh && ~/setup_vm.sh"

# Create staging directory
echo -e "${GREEN}Creating staging directory...${NC}"
STAGING_DIR=$(mktemp -d)

# Copy project files to staging directory
echo -e "${GREEN}Preparing project files...${NC}"
cp -r ../server "$STAGING_DIR/"
cp ../Dockerfile "$STAGING_DIR/"
cp ../docker-compose.yml "$STAGING_DIR/"
cp ../requirements.txt "$STAGING_DIR/"

# Upload files to VM
echo -e "${GREEN}Uploading project files to VM...${NC}"
gcloud compute scp --recurse "$STAGING_DIR"/* "root@$VM_NAME:/opt/custom-tunnel/" --zone="$ZONE"

# Clean up staging directory
rm -rf "$STAGING_DIR"

# Start the service
echo -e "${GREEN}Starting custom tunnel service...${NC}"
gcloud compute ssh "root@$VM_NAME" --zone="$ZONE" -- "cd /opt/custom-tunnel && rc-service custom-tunnel start"

echo
echo -e "${GREEN}=================================${NC}"
echo -e "${GREEN}Deployment completed successfully!${NC}"
echo -e "${GREEN}=================================${NC}"
echo
echo -e "Server IP: ${YELLOW}$EXTERNAL_IP${NC}"
echo -e "Tunnel port: ${YELLOW}8000${NC}"
echo -e "Control port: ${YELLOW}8001${NC}"
echo
echo -e "${YELLOW}To connect with the client:${NC}"
echo -e "python client/client.py --server $EXTERNAL_IP --port 8000 --control-port 8001 --target GAME_SERVER --target-port GAME_PORT"
echo
echo -e "${YELLOW}To check service status:${NC}"
echo -e "gcloud compute ssh \"root@$VM_NAME\" --zone=\"$ZONE\" -- \"rc-service custom-tunnel status\""
echo
echo -e "${YELLOW}To view logs:${NC}"
echo -e "gcloud compute ssh \"root@$VM_NAME\" --zone=\"$ZONE\" -- \"cd /opt/custom-tunnel && docker-compose logs -f\"" 