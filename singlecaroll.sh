# This script demonstrates a child CA doing an algorithm rollover.
# 1.  First, we have a parent krill instace with TA and online CA, using RSA.
# 2.  A separate krill instance (such that we really check communication over the network)
#     is then added as a subordinate CA, again using RSA. There's also a grandchild CA.
# 3.  Then, without changes to the parent / TA, we update the child's configuration 
#     to prefer creating post-quantum keys, and restart it.
# 4.  We then check that the existing RSA keys are still available, by creating a new ROA still with the RSA keypair.
#     This ROA should have a post-quantum EE-cert subject, but an RSA issuer on the EE-cert.
# 5.  Then, we perform a standard key rollover.
# 6.  Finally, we check that we can now create a new ROA with the new post-quantum keypair.
#
# Throughout this migration, we save snapshots of the repositories, such that we can
# check that our updated Routinator can verify correctly at any point in time.
# 
# We create the following snapshots:
# 1:  Using only RSA.
#     - "123.12.23.0/24-24 => 5" created fully with RSA. 
#     - "123.12.34.0/24-24 => 5" with RSA in the grandchild.
# 2:  The child has a post-quantum signer configured, but hasn't rolled.
#     - "123.12.23.0/24-24 => 5" created fully with RSA. 
#     - "123.12.34.0/24-24 => 5" with RSA in the grandchild.
#     - "123.12.23.0/24-24 => 6" with a post-quantum EE key, but RSA issuer. 
# 3:  Keyroll started. ROAs still use the RSA issuer, but the online CA has published a cert for the new post-quantum keypair. The child CA has published empty manifest and CRL for the new keypair.
#     - "123.12.23.0/24-24 => 5" created fully with RSA. 
#     - "123.12.34.0/24-24 => 5" with RSA in the grandchild.
#     - "123.12.23.0/24-24 => 6" with a post-quantum EE key, but RSA issuer. 
# 4:  Keyroll activated. The child CA has reissued the ROAs under the PQ key. The online CA has revoked and removed the resource cert for the old RSA key.
#     - "123.12.23.0/24-24 => 5" with post-quantum EE and issuer.
#     - "123.12.34.0/24-24 => 5" with RSA in the grandchild. AIA now points to the post-quantum "child" CA cert.
#     - "123.12.23.0/24-24 => 6" with post-quantum EE and issuer. 
# 5:  New ROA added with the new post-quantum keypair.
#     - "123.12.23.0/24-24 => 5" with post-quantum EE and issuer.
#     - "123.12.34.0/24-24 => 5" with RSA in the grandchild. AIA now points to the post-quantum "child" CA cert.
#     - "123.12.23.0/24-24 => 6" with post-quantum EE and issuer. 
#     - "123.12.23.0/24-24 => 7" with post-quantum EE and issuer.

set -e

export LOCATION="data/singlecaroll" \
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

# 2. Set up the child CA, using RSA.

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

# Create a ROA in the grandchild krill instance, using an RSA keypair.
krillc roas update --ca grandchild --add "123.12.34.0/24-24 => 5"

# Store current data before starting algorithm migration.
mkdir -p $LOCATION/ta
wget https://localhost:3000/ta/ta.tal --no-check-certificate -q -O $LOCATION/ta/ta.tal
wget https://localhost:3000/ta/ta.cer --no-check-certificate -q -O $LOCATION/ta/ta.cer

snapshot "1"

# 3. Update the child CA to prefer post-quantum keys.
echo "Stopping child krill with old config..."
kill $CHILD_PID || true
wait $CHILD_PID 2>/dev/null || true

echo "Restarting child krill with new config..."
krill -c configs/krill-child-pq-traditional.conf &
CHILD_PID=$!

sleep 1

echo "Checking child krill status..."
krillc info > /dev/null

# 4. Create a new ROA with the RSA keypair.
echo "Creating a new ROA with the RSA keypair but post-quantum one-time key..."
krillc roas update --ca child --add "123.12.23.0/24-24 => 6"

sleep 1

snapshot "2"
# 5. Perform a standard key rollover.

echo "Initiating a key+algorithm rollover..."
krillc show --ca child

krillc health
krillc keyroll init --ca child
sleep 3
krillc show --ca child

snapshot "3"

echo "Activating the new keypair..."
krillc keyroll activate --ca child
sleep 3
krillc show --ca child

snapshot "4"

echo "Creating a new ROA with the new post-quantum keypair..."
krillc roas update --ca child --add "123.12.23.0/24-24 => 7"

sleep 1

snapshot "5"

echo "Shutting down..."
kill $CHILD_PID || true
wait $CHILD_PID 2>/dev/null || true
kill $ONLINE_PID || true
wait $ONLINE_PID 2>/dev/null || true
