import json

def lambda_handler(event, context):
    # log the entire event
    print(event)
    # see https://docs.aws.amazon.com/lambda/latest/dg/python-context-object.html
    # context itself is not serializable
    print(context.__dict__)
    # if you want a reasonable debugging lambda, use this instead
    # response = {
    #     'statusCode': 200,
    #     'body': json.dumps({'meta': {'event': event}})
    # }
    response = {
        'statusCode': 200,
        'body': event['requestContext']['identity']['sourceIp']
    }
    return response
