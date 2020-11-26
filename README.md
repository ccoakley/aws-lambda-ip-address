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

This examines the event variable for the requesting ip address.

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

I have broken down the above steps into a few scripts (combining the IAM
permissions with the lambda creation).

You will need jq (or the equivalent python, or extract important values from the
returned json yourself). If you choose to follow along, I would suggest using a
virtual environment. To test this, I ran:

```bash
python3 -m venv venv
source venv/bin/activate
pip install awscli
```

# Register Domain

There are two key functions to registering a domain:

```bash
aws route53domains check-domain-availability
aws route53domains register-domain
```

One checks availability of the domain name, and the other actually registers the
domain.

This is the set of variables required to register a domain:

```bash
domain_name=mydomain.com
first_name=Jane
last_name=Doe
contact_type=PERSON
address_line_1="123 Some St."
city="North Anytown"
state=CA
country_code=US
zip_code=93333
phone_number=+1.8001234567
email=admin@otherdomain.com
```

First, we check domain availability. Ideally, we'll get a return value that says
the domain is available. The structure looks like this:

```json
'{"Availability": "AVAILABLE"}'
```

Checking the availability:

```bash
availability_return=$(aws route53domains check-domain-availability --domain-name ${domain_name})
echo ${availability_return}
availability=$(echo ${availability_return} | jq -r '.Availability')
```

If our domain is not available, we ask Amazon for 5 alternatives. In practice,
this is unlikely to be helpful. However, it _is_ sometimes useful, and it's an
extra API call that we can provide a contextual example for.

```bash
if [[ ${availability} != AVAILABLE ]]; then
  echo Expected AVAILABLE but got ${availability}
  echo "Amazon's alternatives for ${domain_name}:"
  aws route53domains get-domain-suggestions --domain-name symapi.com --suggestion-count 5 --only-available | jq -r '.SuggestionsList[] | .DomainName'
  exit 1
fi
```

Assemble the contact values into a single shell variable. At the point this is
interpolated, spaces will tend to break things. I have chosen a simple method to
single-quote the "AddressLine1" value.

```bash
contact=FirstName=${first_name},LastName=${last_name},ContactType=${contact_type},AddressLine1="'"${address_line_1}"'",City=${city},State=${state},CountryCode=${country_code},ZipCode=${zip_code},PhoneNumber=${phone_number},Email=${email}
echo ${contact}
```

Now it is time to attempt to register the domain. If your email has already been
verified due to a prior domain registration, the domain should complete
registration in about 15 minutes. Otherwise, check your email and give it 20 to
30 minutes.

```bash
register_return=$(aws route53domains register-domain --domain-name ${domain_name} --duration-in-years 1 --admin-contact "${contact}" --registrant-contact "${contact}" --tech-contact "${contact}")
echo ${register_return}
operation_id=$(echo ${register_return} | jq -r '.OperationId')
echo ${operation_id}
```

We will now get the status of the previous operation in a watch loop. Please
note that if the status is "SUCCESSFUL", then this code will never terminate.

```bash
watch -g aws route53domains get-operation-detail --operation-id ${operation_id}
```

# Create TLS certification

This section describes obtaining an SSL/TLS X.509 certificate from AWS that we
will use to protect the HTTP API endpoint. Note that AWS generates these
certificates for free. However, the process has several steps, including
verification. These steps can be automated, and I have provided the bash below.
(TODO add equivalent python script)

The following bash script assumes that you have python3 installed and that you
have pip installed awscli. I used python3 because I didn't have jq installed. I
have all of the scripts working with jq for parsing the json on the command line
now.

To simplify some string processing in the case of more complex domains like
foo.bar.baz.net.nz, we're going to just ask for both the domain name and the
hosted zone name in route53.

```bash
domain_name='subdomain.domain.com'
parent_domain_zone='domain.com.'
```

Idempotency tokens are optional, but they prevent multiple certs from being
generated on resubmit.

```bash
idempotency_token=$(python3 -c "import uuid; print(uuid.uuid4().hex)")
echo ${idempotency_token}
```

Request the cert. Notice how close to the top of this section we are. The
request is really the first step.

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

# Create IAM Policy for Lambda Role

We will only need to define two shell variable to create the IAM Policy for the
lambda function.

```bash
function_name=request-ip-lambda
region_name=us-east-1
```

The first variable will be our lambda function name. This doesn't have to match
anything in the code. The second variable is the AWS region name. I have chosen
us-east-1, but you might choose a region closer to yourself. I used to work
exclusively out of us-west-2 because it had less latency for my own usage.

We will need another variable defined to fill in the policy template I have
provided. The Account ID is part of the unique identifier that AWS associates
with each resource inside an account. The AWS documentation recommends
[visiting
the support page to obtain your Account ID](https://docs.aws.amazon.com/IAM/latest/UserGuide/console_account-alias.html#FindingYourAWSId). Another way is to parse the arn of
something in your account. If you are a user in your account, as opposed to
having assumed a role within the account, the default for the `aws iam get-user`
call is to return the information for the user making the call. The result has
the Arn for that particular user. The Arn format is
arn:aws:iam::account_id:user/username. Therefore, if we split on ":" and grab
the 5th field, we can get the Account ID.

```bash
account_id=$(aws iam get-user | jq -r '.User.Arn' | cut -d':' -f5)
```

Now we have all of the template variables we need for the policy. Note, we could
have used an asterisk for each of these instead. But reducing the permissions
granted to lambdas, especially those exposed to the outside world, is
worthwhile. In our case, the lambda function will be able to create logs (and
log entries) in Cloudwatch. No other permissions will be granted.

We apply the variables to the policy template with sed and create a temporary
document we can upload.

```bash
cat ./conf/aws/lambda-with-logging-policy.json.template | sed "s/replace_region_name/${region_name}/g" | sed "s/replace_account_id/${account_id}/" | sed "s/replace_function_name/${function_name}" > ./temporary-lambda-with-logging-policy.json
```

Then, we create the policy.

```bash
aws iam create-policy --policy-name lambda-with-logging-policy --policy-document file://./temporary-lambda-with-logging-policy.json
```

Now we can clean up the temporary policy file.

```bash
rm ./temporary-lambda-with-logging-policy.json
```

# Create Role for Lambda

Create a lambda trust role (this allows the aws lambda service to have
_some_ permissions in your account).

```bash
role_return=$(aws iam create-role --role-name ${role_name} --assume-role-policy-document file://../conf/aws/lambda-role-trust-policy.json)
role_arn=$(echo ${role_return} | jq -r '.Role.Arn')
```

Now we attach the role policy that we just created from template.

```bash
aws iam attach-role-policy --role-name ${role_name} --policy-arn ${policy_arn}
```

We have now satisfied the prerequisites for our lambda.

# Install Lambda Function

I have provided the (very simple) python code for the lambda. We need to create
the lambda payload for installation.

```bash
zip ./request-ip-lambda.zip aws_lambda_ip_address.py
```

Now we can create the lambda function.

```bash
aws lambda create-function --function-name ${function_name} --runtime python3.6 --role ${role_arn} --handler aws_lambda_ip_address.lambda_handler --publish --zip-file file://./request-ip-lambda.zip
```

Finally, we can delete the temporary zip payload.

```bash
rm ./request-ip-lambda.zip
```

We now have a lambda, but nothing to trigger it. Let's set up an HTTP trigger
using API gateway, and customize the full URL with route53 and ACM.

# Create API Gateway

To expose the lambda, we will use API Gateway. The first step is to create an API. The actual endpoint and association with the lambda will use this resource.

```bash
create_api_return=$(aws apigateway create-rest-api --name ${api_name} --description ${api_name} --api-key-source HEADER --endpoint-configuration REGIONAL --api-version 0.1.0)
api_id=$(echo ${create_api_return} | jq -r '.id')
```

We are going to associate our lambda with the root path of the api. When we create an API, that resource exists by default. 

```bash
root_resource_return=$(aws apigateway get-resources --rest-api-id ${api_id})
root_resource_id=$(echo ${root_resource_return} | jq -r '.items[0].id')
```

Our particular lambda does not modify state, but instead returns information from the request. For this reason, it is appropriate to use an HTTP GET method.

```bash
aws apigateway put-method --rest-api-id ${api_id} --resource-id ${root_resource_id} --http-method GET --authorization-type NONE --api-key-required
```

We need the ARN for our lambda for the API call that associates it with the endpoint. Fortunately, we can conveniently get that with the lambda name.

```bash
function_arn=$(aws lambda get-function --function-name ${function_name} | jq -r '.Configuration.FunctionArn')
account_id=$(echo ${function_arn} | cut -d':' -f5)
region_name=$(echo ${function_arn} | cut -d':' -f4)
```

Now we associate the lambda function with the other end of the call.

```bash
aws apigateway put-integration --rest-api-id ${api_id} --resource-id ${root_resource_id} --http-method AWS_PROXY --type AWS --integration-http-method POST --uri arn:aws:apigateway:${region_name}:lambda:path/2015-03-31/functions/arn:aws:lambda:${region_name}:${account_id}:function:${function_name}/invocations
```

# Associate the API with the registered domain

Our script is going to need a few values. Let's get the route53 id for our domain.

```bash
zone_id=$(aws route53 list-hosted-zones-by-name --dns-name=${domain_name} --max-items=1 | jq -r '.HostedZones[0].Id')
```

Our endpoint will be access via https, so we will need the ACM cert we created earlier. Get the ARN for the ACM certificate for our domain.

```bash
cert_arn=$(aws acm list-certificates | jq -r ".CertificateSummaryList[] | select(.DomainName==\"${domain_name}\").CertificateArn")
```

Now we actually assocate the domain with our Rest API. Note the use of TLS 1.2. We have to be explicit about this. This tells AWS to serve up the endpoint on the domain name, but it doesn't do the DNS job of routing our domain to the endpoint.

```bash
domain_name_return=$(aws apigateway create-domain-name --domain-name=${domain_name} --regional-certificate-name=${domain_name} --regional-certificate-arn=${cert_arn} --security-policy=TLS_1_2 --endpoint-configuration="types=REGIONAL")
```

It is now time to create the base path mapping. Note that if you do what I am doing here, using "(none)", then this is the only API that can be served on this domain. API Gateway allows the use of multiple base-paths (e.g. v1, v2) so that multiple APIs can be served on the same domain.

```bash
path_mapping_return=$(aws apigateway create-base-path-mapping \
    --domain-name ${domain_name} \
    --base-path '(none)' \
    --rest-api-id ${api_id} \
    --stage default)

regional_domain_name=$(echo ${path_mapping_return} | jq -r '.regionalDomainName')
```

Finally, we are ready to update DNS to point to the endpoint. I have included a template file for the route53 record set change using UPSERT. That allows this one call to be idempotent, but these scripts as a whole are not idempotent, so a CREATE would be just as valid here.

```bash
cat ./conf/aws/setup-dns-record.json.template | sed "s/replace_dns_fqdn/${domain_name}/g" | sed "s/replace_execute_api_dns_name/${regional_domain_name}/" | sed "s/replace_alias_hosted_zone/${alias_hosted_zone}" > ./temporary-setup-dns-record.json

aws route53 change-resource-record-sets --hosted-zone-id ${zone_id} --change-batch file://./temporary-setup-dns-record.json

rm ./temporary-setup-dns-record.json
```

# Create Cognito User Pool

...

# Create DNS Entry
```bash
aws route53 change-resource-record-sets \
     --hosted-zone-id {your-hosted-zone-id} \
     --change-batch file://path/to/your/setup-dns-record.json
```
