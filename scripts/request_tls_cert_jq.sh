# to simplify some string processing in the case of more complex domains like foo.bar.baz.net.nz,
# we're going to just ask for both the domain name and the hosted zone name in route53
domain_name='subdomain.domain.com'
parent_domain_zone='domain.com.'

# Idempotency tokens are optional, but they prevent multiple certs from being generated on resubmit
idempotency_token=$(python3 -c "import uuid; print(uuid.uuid4().hex)")
echo ${idempotency_token}

# request the cert
return_value=$(aws acm request-certificate --domain-name ${domain_name} --validation-method DNS --idempotency-token ${idempotency_token})
echo ${return_value}
certificate_arn=$(echo $return_value | jq -r '.CertificateArn')
echo ${certificate_arn}

# this will tell us how to validate the domain
describe_return=$(aws acm describe-certificate --certificate-arn ${certificate_arn})
echo ${describe_return}

# extract the changes to DNS that AWS wishes for us to make
resource_record=$(echo $describe_return | jq '.Certificate.DomainValidationOptions[0].ResourceRecord')
echo ${resource_record}
validate_name=$(echo ${resource_record} | jq -r '.Name'
validate_name=$(echo ${resource_record} | jq -r '.Value'

# obtain the hosted zone id from the parent domain name
list_zone_return=$(aws route53 list-hosted-zones-by-name --dns-name ${parent_domain_zone})
hosted_zone_id=$(echo ${list_zone_return} | jq -r '.HostedZones[0].Id')

# make the change-batch file
cat ./conf/aws/change-resource-record-sets.json | sed "s/replace_name/${validate_name}/" | sed "s/replace_value/${validate_value}/" > ./temporary-change-resource-record-sets.json

# create the validation entry
record_set_return=$(aws route53 change-resource-record-sets --hosted-zone-id ${hosted_zone_id} --change-batch file://./temporary-change-resource-record-sets.json)
echo ${record_set_return}

# clean up that temporary file
rm ./temporary-change-resource-record-sets.json

# Wait for validation. This took about 17 minutes while I was testing this.
time aws acm wait certificate-validated --certificate-arn ${certificate_arn}
