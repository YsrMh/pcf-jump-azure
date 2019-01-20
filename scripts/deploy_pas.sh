#!/usr/bin/env bash
POSITIONAL=()
while [[ $# -gt 0 ]]
do
key="$1"

case $key in
    -n|--NO_DOWNLOAD)
    NO_DOWNLOAD=TRUE
    echo No download  $NO_DOWNLOAD
    # shift # past value
    ;;
    -d|--DO_NOT_APPLY_CHANGES)
    NO_APPLY=TRUE
    echo No APPLY  $NO_APPLY
    # shift # past value
    ;;    
    *)    # unknown option
    POSITIONAL+=("$1") # save it in an array for later
    shift # past argument
    ;;
esac
shift
done
set -- "${POSITIONAL[@]}" # restore positional parameters
source ~/.env.sh

export OM_TARGET=${PCF_OPSMAN_FQDN}
export OM_USERNAME=${PCF_OPSMAN_USERNAME}
export OM_PASSWORD="${PCF_PIVNET_UAA_TOKEN}"
START_PAS_DEPLOY_TIME=$(date)
$(cat <<-EOF >> ${HOME_DIR}/.env.sh
START_PAS_DEPLOY_TIME="${START_PAS_DEPLOY_TIME}"
EOF
)
source ~/pas.env
PCF_OPSMAN_ADMIN_PASSWD=${PCF_PIVNET_UAA_TOKEN}
#PCF_KEY_PEM=$(cat ${HOME_DIR}/.acme.sh/${PCF_SUBDOMAIN_NAME}.${PCF_DOMAIN_NAME}/${PCF_SUBDOMAIN_NAME}.${PCF_DOMAIN_NAME}.key | awk '{printf "%s\\r\\n", $0}')
#PCF_CERT_PEM=$(cat ${HOME_DIR}/.acme.sh/${PCF_SUBDOMAIN_NAME}.${PCF_DOMAIN_NAME}/fullchain.cer | awk '{printf "%s\\r\\n", $0}')

PCF_KEY_PEM=$(cat ${HOME_DIR}/${PCF_SUBDOMAIN_NAME}.${PCF_DOMAIN_NAME}.key | awk '{printf "%s\\r\\n", $0}')
PCF_CERT_PEM=$(cat ${HOME_DIR}/fullchain.cer | awk '{printf "%s\\r\\n", $0}')
PCF_CREDHUB_KEY="01234567890123456789"
PRODUCT_NAME=cf
PCF_APPS_DOMAIN="apps.${PCF_SUBDOMAIN_NAME}.${PCF_DOMAIN_NAME}"
PCF_SYSTEM_DOMAIN="sys.${PCF_SUBDOMAIN_NAME}.${PCF_DOMAIN_NAME}"
PCF_WEB_LB="${ENV_NAME}-web-lb"
PCF_DIEGO_SSH_LB="${ENV_NAME}-diego-ssh-lb"
PCF_MYSQL_LB="${ENV_NAME}-mysql-lb"

cd ${HOME_DIR}
#Authenticate pivnet 

PIVNET_ACCESS_TOKEN=$(curl \
  --fail \
  --header "Content-Type: application/json" \
  --data "{\"refresh_token\": \"${PCF_PIVNET_UAA_TOKEN}\"}" \
  https://network.pivotal.io/api/v2/authentication/access_tokens |\
    jq -r '.access_token')

# release by slug
RELEASE_JSON=$(curl \
  --header "Authorization: Bearer ${PIVNET_ACCESS_TOKEN}" \
  --fail \
  "https://network.pivotal.io/api/v2/products/${PRODUCT_SLUG}/releases/${RELEASE_ID}")
# eula acceptance link
EULA_ACCEPTANCE_URL=$(echo ${RELEASE_JSON} |\
  jq -r '._links.eula_acceptance.href')


DOWNLOAD_DIR_FULL=${DOWNLOAD_DIR}/$PRODUCT_SLUG/${PCF_PAS_VERSION}-${PAS_EDITION}
mkdir -p ${DOWNLOAD_DIR_FULL}
# eula acceptance
curl \
  --fail \
  --header "Authorization: Bearer ${PIVNET_ACCESS_TOKEN}" \
  --request POST \
  ${EULA_ACCEPTANCE_URL}
# download product using om cli
if  [ -z ${NO_DOWNLOAD} ] ; then

# download product using om cli
echo $(date) start downloading ${PRODUCT_SLUG}
om --skip-ssl-validation \
  download-product \
 --pivnet-api-token ${PCF_PIVNET_UAA_TOKEN} \
 --pivnet-file-glob "${PAS_EDITION}*.pivotal" \
 --pivnet-product-slug ${PRODUCT_SLUG} \
 --product-version ${PCF_PAS_VERSION} \
 --stemcell-iaas azure \
 --download-stemcell \
 --output-directory ${DOWNLOAD_DIR_FULL}
echo $(date) end downloading ${PRODUCT_SLUG}
else 
echo ignoring download by user 
fi

TARGET_FILENAME=$(cat ${DOWNLOAD_DIR_FULL}/download-file.json | jq -r '.product_path')
STEMCELL_FILENAME=$(cat ${DOWNLOAD_DIR_FULL}/download-file.json | jq -r '.stemcell_path')

# Import the tile to Ops Manager.
echo $(date) start uploading ${PRODUCT_SLUG}
om --skip-ssl-validation \
  --request-timeout 3600 \
  upload-product \
  --product ${TARGET_FILENAME}

echo $(date) end uploading ${PRODUCT_SLUG}

    # 1. Find the version of the product that was imported.
PRODUCTS=$(om --skip-ssl-validation \
  available-products \
    --format json)

VERSION=$(echo ${PRODUCTS} |\
  jq --arg product_name ${PRODUCT_NAME} -r 'map(select(.name==$product_name)) | first | .version')

# 2.  Stage using om cli
echo $(date) start staging ${PRODUCT_SLUG} 
om --skip-ssl-validation \
  stage-product \
  --product-name ${PRODUCT_NAME} \
  --product-version ${VERSION}
echo $(date) end staging ${PRODUCT_SLUG} 

cat << EOF > vars.yaml
pcf_pas_network: pcf-pas-subnet
pcf_system_domain: ${PCF_SYSTEM_DOMAIN}
pcf_apps_domain: ${PCF_APPS_DOMAIN}
pcf_notifications_email: ${PCF_NOTIFICATIONS_EMAIL}
pcf_cert_pem: "${PCF_CERT_PEM}"
pcf_key_pem: "${PCF_KEY_PEM}"
pcf_credhub_key: "${PCF_CREDHUB_KEY}"
pcf_diego_ssh_lb: ${PCF_DIEGO_SSH_LB}
pcf_mysql_lb: ${PCF_MYSQL_LB}
pcf_web_lb: ${PCF_WEB_LB}
smtp_address: "${SMTP_ADDRESS}"
smtp_identity: "${SMTP_IDENTITY}"
smtp_password: "${SMTP_PASSWORD}"
smtp_from: "${SMTP_FROM}"
smtp_port: "${SMTP_PORT}"
smtp_enable_starttls_auto: "${SMTP_STARTTLS}"
EOF

om --skip-ssl-validation \
  configure-product \
  -c ${HOME_DIR}/pas-${PAS_EDITION}.yaml -l vars.yaml
###

om --skip-ssl-validation \
  upload-stemcell \
  --stemcell ${STEMCELL_FILENAME}
echo $(date) start apply ${PRODUCT_SLUG}


if  [ -z ${NO_APPLY} ] ; then
om --skip-ssl-validation \
  apply-changes \
  --product-name ${PRODUCT_NAME}
else
echo "No Product Apply"
fi
echo $(date) end apply ${PRODUCT_SLUG}

END_PAS_DEPLOY_TIME=$(date)
$(cat <<-EOF >> ${HOME_DIR}/.env.sh
END_PAS_DEPLOY_TIME="${END_PAS_DEPLOY_TIME}"
EOF
)
echo Finished
echo Started BASE deployment at ${START_BASE_DEPLOY_TIME}
echo Fimnished BASE deployment at ${END_BASE_DEPLOY_TIME}
echo Started OPSMAN deployment at ${START_OPSMAN_DEPLOY_TIME}
echo Finished OPSMAN Deployment at ${END_OPSMAN_DEPLOY_TIME}
echo Started ${PRODUCT_SLUG} deployment at ${START_PAS_DEPLOY_TIME}
echo Finished ${PRODUCT_SLUG} Deployment at ${END_PAS_DEPLOY_TIME}