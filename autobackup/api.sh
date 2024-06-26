#!/bin/bash
# Define Supervisor API URL
BACKUP_API="http://supervisor/backups"
FILE_PATH="/backup/mac_addr.txt"

# Get Mac Address from eth0
MAC_ADDR=$(ip link show eth0 | awk '/ether/ {print $2}')
MAC_ADDR=$(echo $MAC_ADDR | tr -d ':')

# Use the variable as needed
echo $MAC_ADDR > /tmp/mac_address.txt

# Generate a UUID as the backup filename
FILENAME="backup_restored"

# JSON payload to create a new full backup
PAYLOAD='{"name": "'"$FILENAME"'"}'

# Calculate the time until the next 2 AM using Python, adjusted for Singapore's time zone
SLEEP_TIME=$(python3 -c "
import pytz
from datetime import datetime, timedelta

# Specify Singapore time zone
time_zone = pytz.timezone('Asia/Singapore')

# Get the current time in the specified time zone
now = datetime.now(time_zone)

# Check if current time is past 2 AM
if now.hour > 2 or (now.hour == 2 and now.minute > 0):
    # Calculate time until 2 AM next day
    next_2_am = (now + timedelta(days=1)).replace(hour=2, minute=0, second=0, microsecond=0, tzinfo=None)
else:
    # Calculate time until 2 AM today
    next_2_am = now.replace(hour=2, minute=0, second=0, microsecond=0, tzinfo=None)

# Make next_2_am aware of the timezone
next_2_am = time_zone.localize(next_2_am)

# Calculate the difference in seconds
delta = (next_2_am - now).total_seconds()

print(int(delta))
")

echo "Waiting for $SLEEP_TIME seconds until the next 2 AM."

# Sleep for the calculated duration
sleep $SLEEP_TIME

while true; do
    # Create a new backup via Supervisor API
    BACKUP_ID=$(curl -s -X POST -H "Authorization: Bearer ${SUPERVISOR_TOKEN}" -H "Content-Type: application/json" -d "${PAYLOAD}" http://supervisor/backups/new/full | jq -r '.data.slug')

    # Check if the snapshot ID was obtained
    if [ "${BACKUP_ID}" == "null" ] || [ -z "${BACKUP_ID}" ];
    then
        echo "Failed to create backup."
    else
        echo "Backup created successfully. Snapshot ID: ${BACKUP_ID}"
        # Define path where to save the backup file
        BACKUP_PATH="/tmp/${FILENAME}.tar"

        # Download the backup
        curl -s -L -o "${BACKUP_PATH}" -H "Authorization: Bearer ${SUPERVISOR_TOKEN}" "${BACKUP_API}/${BACKUP_ID}/download"

        echo "Backup downloaded successfully to ${BACKUP_PATH}"

        # Fetch the old backup version json file from S3 (check version cache first)
        HTTP_RESPONSE=$(curl -s -o response.txt -w "%{http_code}" -X POST -H "Content-Type: application/json" -d '{"mac_addr": "'${MAC_ADDR}'"}' http://13.250.103.69:5000/getBackupVersion)
        RESPONSE_BODY=$(cat response.txt)
        DIFF=true

        # Handle when there is no backup version json in the cloud
        if [ "$HTTP_RESPONSE" -eq 200 ]; then
            OLD_BACKUP_VERSION_JSON_PATH="/tmp/backup_version.json"
            echo $RESPONSE_BODY  > $OLD_BACKUP_VERSION_JSON_PATH

            # Compare the two json file
            DIFF=$(./compare.sh $BACKUP_PATH $OLD_BACKUP_VERSION_JSON_PATH)
        fi

        # If true, upload and update the json in s3 (update version cache) , else, dont upload
        if [ "$DIFF" = true ]; then
            # Create and upload the version json file, then delete it locally
            version_json_file="./backup.json"
            tar -xf $BACKUP_PATH $version_json_file
            RESPONSE=$(curl -X POST -F file=@"${version_json_file}" -F "mac_addr=\"${MAC_ADDR}\"" http://13.250.103.69:5000/uploadBackupVersion)
            rm $version_json_file     

            # Upload the backup
            RESPONSE=$(curl -X POST -F file=@"${BACKUP_PATH}" -F "mac_addr=\"${MAC_ADDR}\"" http://13.250.103.69:5000/uploadBackupFile)
            echo "s3 response: $RESPONSE"
        else
            echo "Backup is the same, no backup is uploaded to the cloud"
        fi

        # Get file name
        filename=${FILENAME}.tar
        # Get file size
        size=$(du /tmp/${filename} |  awk '{print $1/1000}')
        # Get current timestamp
        sleep_start=$(date +%s)
        # Get timestamp 10 days later
        sleep_end=$(python -c "from datetime import datetime, timedelta; print(int((datetime.now() + timedelta(days=10)).timestamp()))")

        # Store file info in json
        json_file="/tmp/backup_info.json"
        echo "{\"mac_addr\": \"$MAC_ADDR\", \"filename\": \"$filename\", \"size\": $size, \"sleep_start\": $sleep_start, \"sleep_end\": $sleep_end}" > $json_file
        RESPONSE=$(curl -X POST -H "Content-Type: application/json" -d @"${json_file}" http://13.250.103.69:5000/uploadBackupDetails)
        rm $json_file
    fi
    
    sleep 864000  # Sleeps for 10 days
done
