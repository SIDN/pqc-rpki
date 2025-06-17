# This script demonstrates the steady state using RSA keys.
# We create a tree of TA > online CA > child CA > grandchild CA,
# with two separate Krill instances, all using RSA keys.
#
# We create the following snapshots:
# 1:  Using only RSA keys.
#     - "123.12.23.0/24-24 => 5" by the child.
#     - "123.12.34.0/24-24 => 5" by the grandchild.

set -e

export LOCATION="data/steadystate-traditional" \
       KRILL_CLI_TOKEN="foo" \
       TA_CONF="configs/krillta-traditional.conf"

# This allows using 'localhost' in URIs in resource certificates.
export KRILL_TEST=true

rm -rf data/live $LOCATION
mkdir -p $LOCATION/messages

echo "Killing any running krill instances..."
killall krill || true

# Create self-signed TLS certs for the repositories to allow Routinator to verify them.
mkdir -p data/live/krill-data/ssl
mkdir -p data/live/krill-child-data/ssl
mkdir -p data/live/ssl
openssl req -x509 -nodes -new -sha256 -days 1024 -newkey rsa:2048 -keyout data/live/ssl/root.key -out data/live/ssl/root.pem -subj "/C=US/CN=root" 2> /dev/null                                         
openssl x509 -outform pem -in data/live/ssl/root.pem -out data/live/ssl/root.crt 2> /dev/null
openssl req -new -nodes -newkey rsa:2048 -keyout data/live/ssl/localhost.key -out data/live/ssl/localhost.csr -subj "/CN=localhost" 2> /dev/null

cat > data/live/ssl/ext <<EOF
authorityKeyIdentifier=keyid,issuer
basicConstraints=CA:FALSE
keyUsage = digitalSignature, nonRepudiation, keyEncipherment, dataEncipherment
subjectAltName = @alt_names
[alt_names]
DNS.1 = localhost
EOF
openssl x509 -req -sha256 -days 1024 -in data/live/ssl/localhost.csr -CA data/live/ssl/root.pem -CAkey data/live/ssl/root.key -CAcreateserial -extfile data/live/ssl/ext -out data/live/ssl/localhost.crt 2> /dev/null

cp data/live/ssl/localhost.crt data/live/krill-data/ssl/cert.pem
cp data/live/ssl/localhost.key data/live/krill-data/ssl/key.pem
cp data/live/ssl/localhost.crt data/live/krill-child-data/ssl/cert.pem
cp data/live/ssl/localhost.key data/live/krill-child-data/ssl/key.pem

snapshot() {
       LABEL=$1
       echo "Creating snapshot $LABEL..."
       mkdir -p "$LOCATION/$LABEL"
       cp -r data/live/krill-data/repo/rsync/current/ "$LOCATION/$LABEL/repo-online/"
       cp -r data/live/krill-child-data/repo/rsync/current/ "$LOCATION/$LABEL/repo-child/"
       routinator \
              --no-rir-tals \
              --extra-tals-dir $LOCATION/ta \
              --allow-dubious-hosts \
              --rrdp-root-cert data/live/ssl/root.pem \
              --fresh \
              vrps --format json --complete --output $LOCATION/$LABEL/vrps.json \
              2> /dev/null

}

# 1. Set up the TA and online CA.

echo "Starting parent krill..."
krill -c configs/krill-traditional.conf &
ONLINE_PID=$!
export KRILL_CLI_SERVER="https://localhost:3000"

sleep 1

echo "Checking parent krill status..."
krillc info > /dev/null

echo "Starting TA setup..."

krillta proxy init

krillc pubserver server init --rrdp "https://localhost:3000/rrdp/" --rsync "rsync://localhost/repo/"

echo "TA Proxy repo setup..."
krillta proxy repo request 2> $LOCATION/messages/ta-pub-req.xml
krillc pubserver publishers add --request $LOCATION/messages/ta-pub-req.xml 2> $LOCATION/messages/ta-repo-res.xml
krillta proxy repo configure --response $LOCATION/messages/ta-repo-res.xml

echo "TA Signer init..."
krillta proxy --format json id 2> $LOCATION/messages/ta-proxy-id.json
krillta proxy --format json repo contact 2> $LOCATION/messages/ta-proxy-repo-contact.json
krillta signer -c $TA_CONF init --proxy-id $LOCATION/messages/ta-proxy-id.json \
                    --proxy-repository-contact $LOCATION/messages/ta-proxy-repo-contact.json \
                    --tal-https "https://localhost:3000/ta/ta.cer" \
                    --tal-rsync "rsync://localhost/ta/ta.cer"

echo "TA Proxy-Signer association..."
krillta signer -c $TA_CONF --format json show 2> $LOCATION/messages/ta-signer-info.json
krillta proxy signer init --info $LOCATION/messages/ta-signer-info.json

echo "Create 'online' CA..."
krillc add --ca online
krillc --format json show --ca online 2> $LOCATION/messages/online.json
krillta proxy children add --info $LOCATION/messages/online.json 2> $LOCATION/messages/online-add-res.xml
krillta proxy children response --child online 2> $LOCATION/messages/online-parent-res.xml
krillc parents add --ca online --parent ta --response $LOCATION/messages/online-parent-res.xml

echo "Configure 'online' repo..."
krillc repo request --ca online 2> $LOCATION/messages/online-repo-req.xml
krillc pubserver publishers add --request $LOCATION/messages/online-repo-req.xml 2> $LOCATION/messages/online-repo-res.xml
krillc repo configure --ca online --response $LOCATION/messages/online-repo-res.xml

sleep 1

echo "Request a cert from the TA..."
krillta proxy signer make-request 2> /dev/null
krillta proxy --format json signer show-request 2> $LOCATION/messages/ta-signer-req.json
krillta signer -c $TA_CONF process --request $LOCATION/messages/ta-signer-req.json 2> /dev/null
krillta signer -c $TA_CONF --format json last 2> $LOCATION/messages/ta-signer-res.json
krillta proxy signer process-response --response $LOCATION/messages/ta-signer-res.json

echo "Waiting a few seconds...\n"

sleep 1

# 2. Set up the child CA.

echo "Starting child krill..."
krill -c configs/krill-child-traditional.conf &
CHILD_PID=$!

# Most krillc commands now target the child krill instance on a different port.
export KRILL_CLI_SERVER="https://localhost:3001"

sleep 1

echo "Checking child krill status..."
krillc info > /dev/null

krillc pubserver server init --rrdp "https://localhost:3001/rrdp/" --rsync "rsync://localhost/child-repo/"

echo "Adding a CA 'child' under 'online'..."
krillc add --ca child

# Setting up the child's repo in the child krill instance.
krillc repo request --ca child 2> $LOCATION/messages/child-repo-req.xml
krillc pubserver publishers add --request $LOCATION/messages/child-repo-req.xml 2> $LOCATION/messages/child-repo-res.xml
krillc repo configure --ca child --response $LOCATION/messages/child-repo-res.xml
krillc parents request --ca child 2> $LOCATION/messages/child-parent-req.xml

# Accept the request as the online CA.
krillc --server "https://localhost:3000" children add --ca online --child child --ipv4 123.12.0.0/16 --request $LOCATION/messages/child-parent-req.xml 2> $LOCATION/messages/child-parent-res.xml

# Handle the response in the child krill instance.
krillc parents add --ca child --parent online --response $LOCATION/messages/child-parent-res.xml

echo "Waiting a few seconds to allow the resources to be delegated..."
sleep 5

# Create a ROA in the child krill instance, using the RSA keypair.
krillc roas update --ca child --add "123.12.23.0/24-24 => 5"

# Add grandchild CA.
krillc add --ca grandchild
krillc repo request --ca grandchild 2> $LOCATION/messages/grandchild-repo-req.xml
krillc pubserver publishers add --request $LOCATION/messages/grandchild-repo-req.xml 2> $LOCATION/messages/grandchild-repo-res.xml
krillc repo configure --ca grandchild --response $LOCATION/messages/grandchild-repo-res.xml
krillc parents request --ca grandchild 2> $LOCATION/messages/grandchild-parent-req.xml
krillc children add --ca child --child grandchild --ipv4 123.12.34.0/24 --request $LOCATION/messages/grandchild-parent-req.xml 2> $LOCATION/messages/grandchild-parent-res.xml
krillc parents add --ca grandchild --parent child --response $LOCATION/messages/grandchild-parent-res.xml

echo "Waiting a few seconds to allow the resources to be delegated..."
sleep 5

# Create a ROA in the grandchild krill instance, using a RSA keypair.
krillc roas update --ca grandchild --add "123.12.34.0/24-24 => 5"

sleep 1

# Store data.
mkdir -p $LOCATION/ta
wget https://localhost:3000/ta/ta.tal --no-check-certificate -q -O $LOCATION/ta/ta.tal
wget https://localhost:3000/ta/ta.cer --no-check-certificate -q -O $LOCATION/ta/ta.cer

snapshot "1"

echo "Shutting down..."
kill $CHILD_PID || true
wait $CHILD_PID 2>/dev/null || true
kill $ONLINE_PID || true
wait $ONLINE_PID 2>/dev/null || true
