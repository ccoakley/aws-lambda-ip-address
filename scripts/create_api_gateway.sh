#!/bin/bash

set -e

api_name=request-ip-api
function_name=request-ip-lambda
domain_name=mydomain.com

# The regional zone id comes from this document (note, at least one link in amazon docs is broken, so this link may not be stable)
# https://docs.aws.amazon.com/general/latest/gr/apigateway.html
# this is the value for us-east-1
alias_hosted_zone=Z1UJRXOUMOOFQ8

# Create the api
create_api_return=$(aws apigateway create-rest-api --name ${api_name} --description ${api_name} --api-key-source HEADER --endpoint-configuration REGIONAL --api-version 0.1.0)
api_id=$(echo ${create_api_return} | jq -r '.id')

# Grab the resource id for /. At this point, there is exactly 1 resource, the root.
root_resource_return=$(aws apigateway get-resources --rest-api-id ${api_id})
root_resource_id=$(echo ${root_resource_return} | jq -r '.items[0].id')

# Associate GET with the resource
aws apigateway put-method --rest-api-id ${api_id} --resource-id ${root_resource_id} --http-method ANY --authorization-type NONE --api-key-required

# get function arn
function_arn=$(aws lambda get-function --function-name ${function_name} | jq -r '.Configuration.FunctionArn')
account_id=$(echo ${function_arn} | cut -d':' -f5)
region_name=$(echo ${function_arn} | cut -d':' -f4)

# Associate the Lambda function with the other end of the call
aws apigateway put-integration --rest-api-id ${api_id} --resource-id ${root_resource_id} --http-method AWS_PROXY --type AWS --integration-http-method POST --uri arn:aws:apigateway:${region_name}:lambda:path/2015-03-31/functions/arn:aws:lambda:${region_name}:${account_id}:function:${function_name}/invocations

# Get the route53 id for our domain
zone_id=$(aws route53 list-hosted-zones-by-name --dns-name=${domain_name} --max-items=1 | jq -r '.HostedZones[0].Id')

# Get the arn for the ACM Certificate for our domain
cert_arn=$(aws acm list-certificates | jq -r ".CertificateSummaryList[] | select(.DomainName==\"${domain_name}\").CertificateArn")

# Create domain name for api gateway
# note the use of TLS 1.2
domain_name_return=$(aws apigateway create-domain-name --domain-name=${domain_name} --regional-certificate-name=${domain_name} --regional-certificate-arn=${cert_arn} --security-policy=TLS_1_2 --endpoint-configuration="types=REGIONAL")

# Create the base path mapping
path_mapping_return=$(aws apigateway create-base-path-mapping \
    --domain-name ${domain_name} \
    --base-path '(none)' \
    --rest-api-id ${api_id} \
    --stage default)

# extract the regional domain name
regional_domain_name=$(echo ${path_mapping_return} | jq -r '.regionalDomainName')

# create the file with the dns entry
cat ./conf/aws/setup-dns-record.json.template | sed "s/replace_dns_fqdn/${domain_name}/g" | sed "s/replace_execute_api_dns_name/${regional_domain_name}/" | sed "s/replace_alias_hosted_zone/${alias_hosted_zone}" > ./temporary-setup-dns-record.json

# Map 
aws route53 change-resource-record-sets --hosted-zone-id ${zone_id} --change-batch file://./temporary-setup-dns-record.json

# clean up temporary file
rm ./temporary-setup-dns-record.json