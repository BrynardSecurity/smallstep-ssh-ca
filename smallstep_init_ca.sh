#!/bin/bash
#
# This script will launch and configure a step-ca SSH Certificate Authority
# with OIDC and AWS provisioners
#
# See https://smallstep.com/blog/diy-single-sign-on-for-ssh/ for full instructions

OIDC_CLIENT_ID="" # from Azure
OIDC_CLIENT_SECRET="" # from Azure
ALLOWED_DOMAIN=""
CA_NAME=""
ROOT_KEY_PASSWORD=""
EMAIL=""
TENANT_ID=""

OPENID_CONFIG_ENDPOINT="https://login.microsoftonline.com/$TENANT_ID/v2.0/.well-known/openid-configuration"

gitLatestVersion() {
      curl --silent "https://api.github.com/repos/$1/releases/latest" | # Get latest release from GitHub api
          grep '"tag_name":' |                                            # Get tag line
          sed -E 's/.*"([^"]+)".*/\1/' |                                  # Pluck JSON value
          cut -c 2-
}

caVers=$( gitLatestVersion "smallstep/certificates" ) 
curl -sLO https://github.com/smallstep/certificates/releases/download/v$(caVers)/step-ca_$(caVers)_amd64.deb
dpkg -i step-certificates_$(caVers)_amd64.deb

cliVers=$( gitLatestVersion "smallstep/cli" )
curl -sLO https://github.com/smallstep/cli/releases/download/v$(cliVers)/step-cli_$(cliVers)_amd64.deb
dpkg -i step-cli_$(cliVers)_amd64.deb

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
CNAME="tx-aws-sshca01.thebrynards.com"

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

# Use Azure (OIDC) as the default provisioner in the end user's
# ssh configuration template.
sed -i 's/\%p$/%p --provisioner="Azure"/g' /etc/step-ca/templates/ssh/config.tpl

service step-ca start

echo "export STEPPATH=$STEPPATH" >> /root/.profile
