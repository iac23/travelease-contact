import json
import os
import logging
import re
import boto3
import urllib.request
import uuid
from datetime import datetime
import time


# setup logging first
logger = logging.getLogger()
logger.setLevel(logging.INFO)

# Helper function 1 - retrieve Claude secret
def get_claude_api_key():

    # STEP 1: create secrets manager client
    client = boto3.client('secretsmanager')     # talk to Secrets Manager

    # STEP 2: Get secret name from environment variable
    secret_name = os.environ['SECRET_NAME']

    # STEP 3: Call get_secret_value()
    response = client.get_secret_value(SecretId=secret_name)

    # STEP 4: extract and return the secret string
    return response['SecretString']


# Helper function 2 - Lambda calls Claude API with secret
def call_claude_api(api_key, name, email, message):
    url = 'https://api.anthropic.com/v1/messages'

    headers = {
        'x-api-key': api_key,
        'anthropic-version': '2023-06-01',
        'content-type': 'application/json'
    }

    payload = {
        'model': 'claude-sonnet-4-5',
        'max_tokens': 1024,
        'messages': [{
            'role': 'user',
            'content': f"Customer inquiry: Name: {name}, Email: {email}, Message: {message}"
        }]
    }

    req = urllib.request.Request(
        url,
        data=json.dumps(payload).encode('utf-8'),
        headers=headers
    ) 

    with urllib.request.urlopen(req) as response:
        result = json.loads(response.read().decode('utf-8'))
        return result['content'][0]['text']
    
# Helper Function 3 - Store form submission data in DynamoDB
def store_submission(name, email, message, ai_insights):

    # STEP 1: generate unique ID
    submission_id = str(uuid.uuid4())

    # STEP 2: Get current timestamp as Number 
    timestamp = int(time.time()) # follows UNIX epoch

    # STEP 3: Get table resource you're going to use
    dynamodb = boto3.resource('dynamodb')       # creates the DynamoDB resource object
    table_name = os.environ['dynamodb_table']   # Gets the table name from environment variable in main.tf
    table      = dynamodb.Table(table_name)     # Gets specific table using the name string

    # troubleshoot step:
    logger.info(f"Storing item: {submission_id}, {timestamp}, {type(timestamp)}")

    # STEP 4: Store Item data
    table.put_item(
        Item={
            'submission_id': submission_id,
            'timestamp': timestamp,
            'name': name,
            'email': email,
            'message': message,
            'ai_insights': ai_insights,
            'status': 'new'
        }
    )
    # STEP 5: Return ID for success response
    return submission_id 

    # Helper Function 4: SES client to send emails
def send_emails(email, name, message, ai_insights):

    ses_client = boto3.client('ses')
    business_email = os.environ['business_email']

    # STEP 1: Send email to customer
    ses_client.send_email(
        Source=business_email,
        Destination={
            'ToAddresses': [email]
        },
        Message={
            'Subject': {
                'Data': 'We recieved your inquiry'
            },
            'Body': {
                'Text': {
                    'Data': f' Hi {name}, \n\nThank you for contacting us! We will get back to you within 48 hours.\n\nTravelEase Team'
                }
            }
        }
    )
    # STEP 2: Send email to business
    ses_client.send_email(
        Source=business_email,
        Destination={
            'ToAddresses': [business_email]
        },
        Message={
            'Subject': {
                'Data': f'New inquiry from {name}'
            },
            'Body': {
                'Text': {
                    'Data': f"""New customer inquiry:
Name:  {name}          
Email: {email}

Message:
{message}

AI Insights:
{ai_insights}
"""
                }
            }
        }
    )

def lambda_handler(event, context):
    logger.info(f"Received event: {json.dumps(event)}")
    
    try: 
    # STEP 1: Parse body using dict
        form_data = json.loads(event['body'])

    # STEP 2: Extract - get specific fields from dict
        name = form_data.get('name', '').strip()
        email = form_data.get('email', '').strip()
        message = form_data.get('message', '').strip()

    # STEP 3: Validate name / If invalid - return 400 error
        if not name:
            return {
            'statusCode': 400,
            'headers': {
                'Content-Type': 'application/json',
                'Access-Control-Allow-Origin': '*'
            },
            'body': json.dumps({
                'error': 'Name is required'
            })
        }

    # STEP 4.1 Validate email format / If invalid - return 400 error
        if not email:                  
            return {
            'statusCode': 400,
            'headers': {
                'Content-Type': 'application/json',
                'Access-Control-Allow-Origin': '*'
            },
            'body': json.dumps({
                'message': 'Invalid email'
            })
        }  
    # STEP 4.2 Validate email format
        email_pattern = r'^[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}$'
        if not re.match(email_pattern, email):
            return {
            'statusCode': 400,
            'headers': {
                'Content-Type': 'application/json',
                'Access-Control-Allow-Origin': '*'
            },
            'body': json.dumps({
                'message': 'Invalid email format'
            })
        }

    # STEP 5: Validate message / If invalid - return 400 error    
        if not message:
            return {
            'statusCode': 400,
            'headers': {
                'Content-Type': 'application/json',
                'Access-Control-Allow-Origin': '*'
            },
            'body': json.dumps({
                'message': 'Invalid message'
            })
        }


# GET CLAUDE API KEY from helper function

        logger.info('Retrieving Claude API key from secrets manager')
        claude_api_key = get_claude_api_key()       # calls helper and stores secret in variable
        logger.info('Successfully retrieved API key')

# CALL CLAUDE API

        logger.info('Calling Claude API')
        ai_insights = call_claude_api(claude_api_key, name, email, message)
        logger.info(f"Received insights: {ai_insights[:100]}...") # logs first 100 characters

        logger.info(f"AI Insights type:{type(ai_insights)}")
        logger.info(f"AI Insights length: {len(ai_insights) if isinstance(ai_insights, str) else 'not a string'}")

# STORE DATA IN DYNAMODB

        logger.info('Storing submission in DynamoDB')
        submission_id = store_submission(name, email, message, ai_insights)
        logger.info(f"Stored with ID: {submission_id}")

# SEND SES EMAILS: customer and business emails

        logger.info('Sending email notifications')
        send_emails(email, name, message, ai_insights)
        logger.info('Emails sent successfully')


    # STEP 6: Return success (only if ALL pass)
        return {
        'statusCode': 200,                          # HTTP status for browser
        'headers':  {                               # HTTP headers for browser
            'Content-Type': 'application/json',
            'Access-Control-Allow-Origin': '*'      # CORS HEADER
        },
        'body': json.dumps({                         # Message sent to frontend
            'message': 'Form submitted successfully!',
            'submissionId': submission_id
        })
        } 
    
    except Exception as e:      # This handles errors
        logger.error(f"Error processing request: {str(e)}")
        return {
            'statusCode': 500,
            'headers': {
                'Content-Type': 'application/json',
                'Access-Control-Allow-Origin': '*'
            },
            'body': json.dumps({
                'error': "Internal server error"
            })
    }