# ============================================================
# purchase.py — Step 1: User clicks "Buy Ticket"
# ============================================================
# What this file does in plain English:
#   1. Someone sends a request to buy a ticket
#   2. We check if they gave us the right info (event, tier, how many tickets)
#   3. We check if tickets are still available
#   4. If yes — we hold the tickets for them for 10 minutes
#   5. We put their payment request in a queue to process later
#   6. We immediately tell them "your tickets are held!"
#
# Why a queue? Because during a flash sale, 5000 people might
# click at the same time. The queue handles the rush so nothing crashes.
# ============================================================

import json        # Used to read/write data in JSON format (like a dictionary)
import boto3       # AWS SDK — lets us talk to DynamoDB, SQS, etc.
import uuid        # Generates unique random IDs (like a ticket number)
import time        # Used to get the current timestamp
import os          # Used to read environment variables (config values)
import logging     # Used to write logs so we can debug later
from botocore.exceptions import ClientError  # Catches AWS-specific errors

# Set up logging — this writes messages to CloudWatch
logger = logging.getLogger()
logger.setLevel(logging.INFO)

# Connect to AWS services
dynamodb = boto3.resource('dynamodb')   # Our database
sqs = boto3.client('sqs')               # Our message queue

# These values come from Terraform (set as Lambda environment variables)
TABLE_NAME = os.environ['DYNAMODB_TABLE']   # Name of our DynamoDB table
QUEUE_URL  = os.environ['SQS_QUEUE_URL']    # URL of our SQS payment queue

# How long we hold tickets before releasing them back (10 minutes)
RESERVATION_TTL_SECONDS = 600


# -------------------------------------------------------
# MAIN FUNCTION — AWS calls this when a request comes in
# 'event' = the HTTP request data
# 'context' = AWS metadata (we don't use this much)
# -------------------------------------------------------
def lambda_handler(event, context):

    try:
        # --- Step 1: Read what the user sent us ---
        # The request body comes as a JSON string, so we parse it
        body = json.loads(event.get('body', '{}'))

        event_id       = body.get('eventId')                        # Which concert/event?
        tier           = body.get('tier')                           # Which ticket type? (GA, VIP, etc.)
        quantity       = int(body.get('quantity', 1))               # How many tickets? (default 1)
        idempotency_key = body.get('idempotencyKey', str(uuid.uuid4()))  # Prevents duplicate purchases

        # Get the user's ID from their login token (Cognito JWT)
        # API Gateway automatically adds this to the request
        user_id = (
            event
            .get('requestContext', {})
            .get('authorizer', {})
            .get('claims', {})
            .get('sub', 'anonymous')
        )

        # --- Step 2: Make sure the request is valid ---
        if not event_id or not tier:
            return _response(400, {'error': 'Please provide eventId and tier'})

        if quantity < 1 or quantity > 8:
            return _response(400, {'error': 'You can only buy between 1 and 8 tickets'})

        logger.info(f"New purchase attempt — user: {user_id}, event: {event_id}, tier: {tier}, qty: {quantity}")

        # --- Step 3: Try to grab the tickets (atomic = thread-safe) ---
        # This is the most important part!
        # We tell DynamoDB: "subtract the quantity, BUT ONLY if there are enough left"
        # DynamoDB does this in one single operation — so even if 1000 people
        # try at the exact same millisecond, nobody gets oversold.
        table          = dynamodb.Table(TABLE_NAME)
        reservation_id = str(uuid.uuid4())                              # Unique ID for this reservation
        expires_at     = int(time.time()) + RESERVATION_TTL_SECONDS     # When this hold expires

        try:
            table.update_item(
                Key={
                    'EventID': event_id,
                    'Tier': tier
                },
                # Subtract the requested quantity from available tickets
                UpdateExpression='SET AvailableCount = AvailableCount - :dec',
                # Only do it IF there are enough tickets left (the safety check)
                ConditionExpression='AvailableCount >= :qty',
                ExpressionAttributeValues={
                    ':dec': quantity,   # How many to subtract
                    ':qty': quantity    # The minimum required (same number)
                }
            )
        except ClientError as e:
            # DynamoDB throws this error when the condition fails = sold out!
            if e.response['Error']['Code'] == 'ConditionalCheckFailedException':
                logger.warning(f"Sold out — event: {event_id}, tier: {tier}")
                return _response(409, {
                    'status': 'SOLD_OUT',
                    'message': 'Sorry, no tickets left for this tier!'
                })
            raise  # Re-raise any other unexpected errors

        # --- Step 4: Save the reservation to the database ---
        # We record that this user has tickets on hold
        # The TTL field tells DynamoDB to auto-delete this record after 10 minutes
        # if payment never comes through
        table.put_item(
            Item={
                'EventID':        f'RESERVATION#{reservation_id}',  # Key format for reservations
                'Tier':           tier,
                'ReservationID':  reservation_id,
                'UserID':         user_id,
                'Quantity':       quantity,
                'Status':         'PENDING_PAYMENT',    # Waiting for payment
                'IdempotencyKey': idempotency_key,      # Prevents duplicate charges
                'CreatedAt':      int(time.time()),
                'ExpiresAt':      expires_at,
                'TTL':            expires_at            # DynamoDB will auto-delete after this time
            }
        )

        # --- Step 5: Put the payment job in the queue ---
        # We don't process payment right here — that would be too slow.
        # Instead we drop a message in SQS and payment.py picks it up.
        # This way we respond to the user instantly (<100ms)
        sqs.send_message(
            QueueUrl=QUEUE_URL,
            MessageBody=json.dumps({
                'reservation_id':  reservation_id,
                'user_id':         user_id,
                'event_id':        event_id,
                'tier':            tier,
                'quantity':        quantity,
                'idempotency_key': idempotency_key,
                'timestamp':       int(time.time())
            }),
            MessageGroupId=event_id,               # Keep messages for same event in order
            MessageDeduplicationId=idempotency_key  # Prevent duplicate queue entries
        )

        logger.info(f"Reservation saved — id: {reservation_id}, expires in: {RESERVATION_TTL_SECONDS}s")

        # --- Step 6: Tell the user their tickets are held ---
        return _response(200, {
            'status':        'RESERVED',
            'reservationId': reservation_id,
            'expiresIn':     RESERVATION_TTL_SECONDS,
            'message':       'Tickets reserved! You have 10 minutes to complete payment.'
        })

    except Exception as e:
        # Something unexpected went wrong — log it and tell the user nicely
        logger.error(f"Unexpected error: {str(e)}", exc_info=True)
        return _response(500, {'error': 'Something went wrong on our end. Please try again.'})


# -------------------------------------------------------
# Helper: Build a standard HTTP response
# Every Lambda response needs this exact structure
# -------------------------------------------------------
def _response(status_code, body):
    return {
        'statusCode': status_code,
        'headers': {
            'Content-Type': 'application/json',
            'Access-Control-Allow-Origin': '*'   # Allow requests from any domain (CORS)
        },
        'body': json.dumps(body)
    }
