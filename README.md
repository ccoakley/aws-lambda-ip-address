# aws-lambda-ip-address
AWS Lambda function yields the ip address of the request origin

This is most certainly a work in progress.

The actual lambda function here is trivial. In fact, the entire lambda comes
down to the following:

```python
def lambda_handler(event, context):
    return {
        'statusCode': 200,
        'body': event['requestContext']['identity']['sourceIp']
    }
```

This examines the event for the requesting ip address.

The bulk of this repo is defining and deploying this lambda using API Gateway.

The steps can be manually followed or scripted. However, be advised that the
scripted solution requires a lot of permissions on an AWS account. You should
never execute such code without completely understanding the consequences.

## Steps Overview
1. Register Domain
2. Create TLS certification
3. Create Policy for Lambda Function
4. Create Role for Lambda Function
5. Install Lambda Function
6. Create API Gateway
7. Create DNS Entry

# Register Domain
aws route53domains check-domain-availability
aws route53domains register-domain

# Create TLS certification

This section describes obtaining an SSL/TLS X.509 certificate from AWS that we
will use to protect the HTTP API endpoint. Note that AWS generates these certificates
for free. However, the process has several steps, including verification. These
steps can be automated, and I have provided the bash below. (TODO add equivalent python script)

The following bash script assumes that you have python3 installed and that you have pip installed awscli.
I use python3 because parsing json on the command line is not my favorite activity.
If you are typing this out in bash, then you can also extract the important return
values yourself.

I would suggest using a virtual environment. To test this, I ran:
```bash
python3 -m venv venv
source venv/bin/activate
pip install awscli
```

To simplify some string processing in the case of more complex domains like foo.bar.baz.net.nz,
we're going to just ask for both the domain name and the hosted zone name in route53.

```bash
domain_name='subdomain.domain.com'
parent_domain_zone='domain.com.'
```

Idempotency tokens are optional, but they prevent multiple certs from being generated on resubmit.
```bash
idempotency_token=$(python3 -c "import uuid; print(uuid.uuid4().hex)")
echo ${idempotency_token}
```

Request the cert. Notice how close to the top of this section we are.
```bash
return_value=$(aws acm request-certificate --domain-name ${domain_name} --validation-method DNS --idempotency-token ${idempotency_token})
echo ${return_value}
certificate_arn=$(echo $return_value | python3 -c "import json, sys; print(json.load(sys.stdin)['CertificateArn'])")
echo ${certificate_arn}
```

This will tell us how to validate the domain.
```bash
describe_return=$(aws acm describe-certificate --certificate-arn ${certificate_arn})
echo ${describe_return}
```

Extract the changes to DNS that AWS wishes for us to make.
```bash
resource_record=$(echo $describe_return | python3 -c "import json, sys; print(json.dumps(json.load(sys.stdin)['Certificate']['DomainValidationOptions'][0]['ResourceRecord']))")
echo ${resource_record}
validate_name=$(echo ${resource_record} | python3 -c "import json, sys; print(json.load(sys.stdin)['Name'])")
validate_value=$(echo ${resource_record} | python3 -c "import json, sys; print(json.load(sys.stdin)['Value'])")
```

Obtain the hosted zone id from the parent domain name.
```bash
list_zone_return=$(aws route53 list-hosted-zones-by-name --dns-name ${parent_domain_zone})
hosted_zone_id=$(echo ${list_zone_return} | python3 -c "import json, sys; print(json.load(sys.stdin)['HostedZones'][0]['Id'])")
```

Make the change-batch file.
```bash
cat ./conf/aws/change-resource-record-sets.json.template | sed "s/replace_name/${validate_name}/" | sed "s/replace_value/${validate_value}/" > ./temporary-change-resource-record-sets.json
```

Create the validation entry.
```bash
record_set_return=$(aws route53 change-resource-record-sets --hosted-zone-id ${hosted_zone_id} --change-batch file://./temporary-change-resource-record-sets.json)
echo ${record_set_return}
```

Clean up that temporary file.
```bash
rm ./temporary-change-resource-record-sets.json
```

Wait for validation. This took about 17 minutes while I was testing this.
```bash
time aws acm wait certificate-validated --certificate-arn ${certificate_arn}
```

# Create DNS Entry
```bash
aws route53 change-resource-record-sets \
     --hosted-zone-id {your-hosted-zone-id} \
     --change-batch file://path/to/your/setup-dns-record.json
```
