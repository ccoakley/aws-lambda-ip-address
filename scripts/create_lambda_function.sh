function_name=request-ip-lambda
region_name=us-east-1
role_name=lambda-with-logging-role

# when run from a user account, get-user defaults to that user
# the result has the Arn for that particular user
# the arn format is arn:aws:iam::account_id:user/username
# we split on : and grab the 5th field
account_id=$(aws iam get-user | jq -r '.User.Arn' | cut -d':' -f5)

# apply the variables to the policy template
cat ../conf/aws/lambda-with-logging-policy.json.template | sed "s/replace_region_name/${region_name}/g" | sed "s/replace_account_id/${account_id}/" | sed "s/replace_function_name/${function_name}" > ./temporary-lambda-with-logging-policy.json

# create the policy
aws iam create-policy --policy-name lambda-with-logging-policy --policy-document file://./temporary-lambda-with-logging-policy.json

# clean up temporary file
rm ./temporary-lambda-with-logging-policy.json

# create the role
role_return=$(aws iam create-role --role-name ${role_name} --assume-role-policy-document file://../conf/aws/lambda-role-trust-policy.json)
role_arn=$(echo ${role_return} | jq -r '.Role.Arn')

# attach the role policy
aws iam attach-role-policy --role-name ${role_name} --policy-arn ${policy_arn}

# create the lambda payload
zip ./request-ip-lambda.zip ../aws_lambda_ip_address.py

# create the lambda function
aws lambda create-function --function-name ${function_name} --runtime python3.6 --role ${role_arn} --handler aws_lambda_ip_address.lambda_handler --publish --zip-file file://./request-ip-lambda.zip

# delete the payload
rm ./request-ip-lambda.zip
