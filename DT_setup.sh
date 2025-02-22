#!/bin/bash

# Step 1: Download the setCloud2EdgeEnv.sh script to /tmp
echo "Downloading the setCloud2EdgeEnv.sh script to /tmp..."
curl https://www.eclipse.org/packages/packages/cloud2edge/scripts/setCloud2EdgeEnv.sh \
  --output /tmp/setCloud2EdgeEnv.sh

if [ $? -ne 0 ]; then
  echo "Error: Failed to download setCloud2EdgeEnv.sh."
  exit 1
fi

echo "Download complete."

# Step 2: Make the script executable
echo "Making setCloud2EdgeEnv.sh executable..."
chmod u+x /tmp/setCloud2EdgeEnv.sh

if [ $? -ne 0 ]; then
  echo "Error: Failed to make setCloud2EdgeEnv.sh executable."
  exit 1
fi

echo "Script is now executable."

# Step 3: Define environment variables
echo "Defining environment variables..."
RELEASE="c2e"
NS="cloud2edge"
TRUSTSTORE_PATH="/tmp/c2e_hono_truststore.pem"

echo "RELEASE: $RELEASE"
echo "NS: $NS"
echo "TRUSTSTORE_PATH: $TRUSTSTORE_PATH"

# Step 4: Execute the setCloud2EdgeEnv.sh script
echo "Executing setCloud2EdgeEnv.sh script..."
eval $(/tmp/setCloud2EdgeEnv.sh $RELEASE $NS $TRUSTSTORE_PATH)

if [ $? -ne 0 ]; then
  echo "Error: Failed to execute setCloud2EdgeEnv.sh."
  exit 1
fi

# Step 5: Check if DITTO_API_BASE_URL is set
echo "Checking if DITTO_API_BASE_URL is set..."
if [ -z "$DITTO_API_BASE_URL" ]; then
  echo "Error: DITTO_API_BASE_URL environment variable is not set."
  exit 1
fi

echo "DITTO_API_BASE_URL is set to: $DITTO_API_BASE_URL"

# Step 6: Define additional variables
echo "Defining additional environment variables..."
DITTO_USERNAME="ditto"
DITTO_PASSWORD="ditto"
POLICY_ID="org.acme:my-policy"
HONO_TENANT="OLSR-Testbed"

echo "DITTO_USERNAME: $DITTO_USERNAME"
echo "DITTO_PASSWORD: $DITTO_PASSWORD"
echo "POLICY_ID: $POLICY_ID"
echo "HONO_TENANT: $HONO_TENANT"

# Step 7: Fetch the Ditto DevOps password
echo "Fetching the Ditto DevOps password..."
DITTO_DEVOPS_PWD=$(kubectl --namespace ${NS} get secret ${RELEASE}-ditto-gateway-secret -o jsonpath="{.data.devops-password}" | base64 --decode)

if [ $? -ne 0 ]; then
  echo "Error: Failed to fetch Ditto DevOps password."
  exit 1
fi

echo "DITTO_DEVOPS_PWD fetched successfully."

# Step 8: Print the API Base URL
echo "Setup complete."
echo "Using Ditto API Base URL: $DITTO_API_BASE_URL"


#Finished with variables!


# Devices to Register and Create Twins For
declare -a DEVICES=("pi-1" "pi-2" "pi-3" "pi-4")
PASSWORD="auebiot123"

# Step 1: Create a New Tenant in Hono
echo "Creating new tenant 'Testbed' in Hono..."
curl -i -k -X POST ${REGISTRY_BASE_URL}/v1/tenants/Testbed || { echo "Failed to create tenant 'Testbed'"; exit 1; }
echo "Tenant 'Testbed' created."

# Step 2: Register Devices in Hono
for DEVICE in "${DEVICES[@]}"; do
  DEVICE_ID="org.acme:${DEVICE}"
  echo "Registering device ${DEVICE_ID} in Hono..."
  curl -i -k -X POST ${REGISTRY_BASE_URL}/v1/devices/${HONO_TENANT}/${DEVICE_ID} || { echo "Failed to register device ${DEVICE_ID}"; exit 1; }
  echo "Device ${DEVICE_ID} registered."
done

# Step 3: Set Device Credentials
for DEVICE in "${DEVICES[@]}"; do
  DEVICE_ID="org.acme:${DEVICE}"
  AUTH_ID="${DEVICE}-id"
  echo "Setting credentials for device ${DEVICE_ID}..."
  curl -i -k -X PUT -H "Content-Type: application/json" --data "[
    {
      \"type\": \"hashed-password\",
      \"auth-id\": \"${AUTH_ID}\",
      \"secrets\": [{
        \"pwd-plain\": \"${PASSWORD}\"
      }]
    }
  ]" ${REGISTRY_BASE_URL}/v1/credentials/${HONO_TENANT}/${DEVICE_ID} || { echo "Failed to set credentials for device ${DEVICE_ID}"; exit 1; }
  echo "Credentials set for device ${DEVICE_ID}."
done

# Step 4: Set Up AMQP Connection
echo "Setting up AMQP connection..."
curl -i -X PUT -u devops:${DITTO_DEVOPS_PWD} -H 'Content-Type: application/json' --data "{
  \"name\": \"[Hono/AMQP1.0] ${HONO_TENANT}\",
  \"connectionType\": \"amqp-10\",
  \"connectionStatus\": \"open\",
  \"uri\": \"amqp://consumer%40HONO:verysecret@${RELEASE}-hono-dispatch-router-ext:15672\",
  \"failoverEnabled\": true,
  \"sources\": [
    {
      \"addresses\": [
        \"telemetry/${HONO_TENANT}\",
        \"event/${HONO_TENANT}\"
      ],
      \"authorizationContext\": [
        \"pre-authenticated:hono-connection-${HONO_TENANT}\"
      ],
      \"enforcement\": {
        \"input\": \"{{ header:device_id }}\",
        \"filters\": [
          \"{{ entity:id }}\"
        ]
      },
      \"headerMapping\": {
        \"hono-device-id\": \"{{ header:device_id }}\",
        \"content-type\": \"{{ header:content-type }}\"
      },
      \"replyTarget\": {
        \"enabled\": true,
        \"address\": \"{{ header:reply-to }}\",
        \"headerMapping\": {
          \"to\": \"command/${HONO_TENANT}/{{ header:hono-device-id }}\",
          \"subject\": \"{{ header:subject | fn:default(topic:action-subject) | fn:default(topic:criterion) }}-response\",
          \"correlation-id\": \"{{ header:correlation-id }}\",
          \"content-type\": \"{{ header:content-type | fn:default('application/vnd.eclipse.ditto+json') }}\"
        },
        \"expectedResponseTypes\": [
          \"response\",
          \"error\"
        ]
      },
      \"acknowledgementRequests\": {
        \"includes\": [],
        \"filter\": \"fn:filter(header:qos,'ne','0')\"
      }
    },
    {
      \"addresses\": [
        \"command_response/${HONO_TENANT}/replies\"
      ],
      \"authorizationContext\": [
        \"pre-authenticated:hono-connection-${HONO_TENANT}\"
      ],
      \"headerMapping\": {
        \"content-type\": \"{{ header:content-type }}\",
        \"correlation-id\": \"{{ header:correlation-id }}\",
        \"status\": \"{{ header:status }}\"
      },
      \"replyTarget\": {
        \"enabled\": false,
        \"expectedResponseTypes\": [
          \"response\",
          \"error\"
        ]
      }
    }
  ],
  \"targets\": [
    {
      \"address\": \"command/${HONO_TENANT}\",
      \"authorizationContext\": [
        \"pre-authenticated:hono-connection-${HONO_TENANT}\"
      ],
      \"topics\": [
        \"_/_/things/live/commands\",
        \"_/_/things/live/messages\"
      ],
      \"headerMapping\": {
        \"to\": \"command/${HONO_TENANT}/{{ thing:id }}\",
        \"subject\": \"{{ header:subject | fn:default(topic:action-subject) }}\",
        \"content-type\": \"{{ header:content-type | fn:default('application/vnd.eclipse.ditto+json') }}\",
        \"correlation-id\": \"{{ header:correlation-id }}\",
        \"reply-to\": \"{{ fn:default('command_response/${HONO_TENANT}/replies') | fn:filter(header:response-required,'ne','false') }}\"
      }
    },
    {
      \"address\": \"command/${HONO_TENANT}\",
      \"authorizationContext\": [
        \"pre-authenticated:hono-connection-${HONO_TENANT}\"
      ],
      \"topics\": [
        \"_/_/things/twin/events\",
        \"_/_/things/live/events\"
      ],
      \"headerMapping\": {
        \"to\": \"command/${HONO_TENANT}/{{ thing:id }}\",
        \"subject\": \"{{ header:subject | fn:default(topic:action-subject) }}\",
        \"content-type\": \"{{ header:content-type | fn:default('application/vnd.eclipse.ditto+json') }}\",
        \"correlation-id\": \"{{ header:correlation-id }}\"
      }
    }
  ]
}" "${DITTO_API_BASE_URL}/api/2/connections/hono-amqp-connection-for-${HONO_TENANT//./_}" || { echo "Failed to set up AMQP connection"; exit 1; }
echo "AMQP connection setup complete."


# Step 5: Create Common Policy
echo "Setting up common policy..."
curl -i -X PUT -u ${DITTO_USERNAME}:${DITTO_PASSWORD} -H "Content-Type: application/json" --data "{
  \"entries\": {
    \"DEFAULT\": {
      \"subjects\": {
        \"{{ request:subjectId }}\": {
          \"type\": \"Ditto user authenticated via nginx\"
        }
      },
      \"resources\": {
        \"thing:/\": {
          \"grant\": [\"READ\", \"WRITE\"],
          \"revoke\": []
        },
        \"policy:/\": {
          \"grant\": [\"READ\", \"WRITE\"],
          \"revoke\": []
        },
        \"message:/\": {
          \"grant\": [\"READ\", \"WRITE\"],
          \"revoke\": []
        }
      }
    },
    \"HONO\": {
      \"subjects\": {
        \"pre-authenticated:hono-connection-${HONO_TENANT}\": {
          \"type\": \"Connection to Eclipse Hono\"
        }
      },
      \"resources\": {
        \"thing:/\": {
          \"grant\": [\"READ\", \"WRITE\"],
          \"revoke\": []
        },
        \"message:/\": {
          \"grant\": [\"READ\", \"WRITE\"],
          \"revoke\": []
        }
      }
    }
  }
}" ${DITTO_API_BASE_URL}/api/2/policies/${POLICY_ID} || { echo "Failed to create policy"; exit 1; }
echo "Common policy setup complete."

# Step 6: Create Digital Twins in Ditto
for DEVICE in "${DEVICES[@]}"; do
  DEVICE_ID="org.acme:${DEVICE}"
  echo "Creating digital twin for ${DEVICE_ID} with location 'Greece'..."
  curl -i -X PUT -u ${DITTO_USERNAME}:${DITTO_PASSWORD} -H "Content-Type: application/json" --data "{
    \"policyId\": \"${POLICY_ID}\",
    \"attributes\": {
      \"location\": \"Greece\"
    },
    \"features\": {
      \"network\": {
        \"properties\": {
          \"neighbors\": [],
          \"hl_int\": null,        
          \"tc_int\": null,
          \"error\": null
        }
      }
    }
  }" "${DITTO_API_BASE_URL}/api/2/things/${DEVICE_ID}" || { echo "Failed to create digital twin for ${DEVICE_ID}"; exit 1; }
  echo "Digital twin created for ${DEVICE_ID}."
done

# Final Message
echo "All devices registered in Hono and digital twins created in Ditto with location set to 'Greece'."
