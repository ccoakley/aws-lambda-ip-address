api_name=request-ip-api
function_name=request-ip-lambda

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
