#!/bin/bash
#
# This script will launch and configure a step-ca SSH Certificate Authority
# with OIDC and AWS provisioners
#
# See https://smallstep.com/blog/diy-single-sign-on-for-ssh/ for full instructions

OIDC_CLIENT_ID="5416443c-a718-4043-ab9f-20e6c8b1db2a" # from Azure
OIDC_CLIENT_SECRET="_2BInrGPm72Qp_5_~TT8J~OwNr0fBpOLKO" # from Azure
ALLOWED_DOMAIN="thebrynards.com,brynardsecurity.com"
CA_NAME="SSH CA"
ROOT_KEY_PASSWORD="90mLGBlBZC-JKt12dt.QTV5z..hSVMc8X4"
EMAIL="ralph@thebrynards.com"

OPENID_CONFIG_ENDPOINT="https://login.microsoftonline.com/4f5e45fb-4db4-464a-a8d2-f72ee1494603/v2.0/.well-known/openid-configuration"

curl -sLO https://github.com/smallstep/certificates/releases/download/v0.15.11/step-ca_0.15.11_amd64.deb
dpkg -i step-certificates_0.15.11_amd64.deb

curl -sLO https://github.com/smallstep/cli/releases/download/v0.15.14/step-cli_0.15.14_amd64.deb
dpkg -i step-cli_0.15.14_amd64.deb

# All your CA config and certificates will go into $STEPPATH.
export STEPPATH=/etc/step-ca
mkdir -p $STEPPATH
chmod 700 $STEPPATH
echo $ROOT_KEY_PASSWORD > $STEPPATH/password.txt

# Add a service to systemd for our CA.
cat<<EOF > /etc/systemd/system/step-ca.service
[Unit]
Description=step-ca service
After=network.target
StartLimitIntervalSec=0

[Service]
Type=simple
Restart=always
RestartSec=1
User=root
Environment=STEPPATH=/etc/step-ca
ExecStart=/usr/bin/step-ca ${STEPPATH}/config/ca.json --password-file=${STEPPATH}/password.txt

[Install]
WantedBy=multi-user.target
EOF

LOCAL_HOSTNAME=`curl -s http://169.254.169.254/latest/meta-data/local-hostname`
LOCAL_IP=`curl -s http://169.254.169.254/latest/meta-data/local-ipv4`
PUBLIC_HOSTNAME=`curl -s http://169.254.169.254/latest/meta-data/public-hostname`
PUBLIC_IP=`curl -s http://169.254.169.254/latest/meta-data/public-ipv4`
AWS_ACCOUNT_ID=`curl -s http://169.254.169.254/latest/dynamic/instance-identity/document | grep accountId | awk '{print $3}' | sed  's/"//g' | sed 's/,//g'`

# Set up our basic CA configuration and generate root keys
step ca init --ssh --name="$CA_NAME" \
     --dns="$LOCAL_IP,$LOCAL_HOSTNAME,$PUBLIC_IP,$PUBLIC_HOSTNAME" \
     --address=":443" --provisioner="$EMAIL" \
     --password-file="$STEPPATH/password.txt"

# Add the Azure OAuth provisioner, for user certificates
step ca provisioner add Azure --type=oidc --ssh \
    --client-id="$OIDC_CLIENT_ID" \
    --client-secret="$OIDC_CLIENT_SECRET" \
    --configuration-endpoint="$OPENID_CONFIG_ENDPOINT" \
    --domain="$ALLOWED_DOMAIN" \
    --listenAddress="localhost:8443"

# Add the AWS provisioner, for host bootstrapping
step ca provisioner add "Amazon Web Services" --type=AWS --ssh \
    --aws-account=$AWS_ACCOUNT_ID

# The sshpop provisioner lets hosts renew their ssh certificates
step ca provisioner add SSHPOP --type=sshpop --ssh

# Use Google (OIDC) as the default provisioner in the end user's
# ssh configuration template.
sed -i 's/\%p$/%p --provisioner="Azure"/g' /etc/step-ca/templates/ssh/config.tpl

service step-ca start

echo "export STEPPATH=$STEPPATH" >> /root/.profile
