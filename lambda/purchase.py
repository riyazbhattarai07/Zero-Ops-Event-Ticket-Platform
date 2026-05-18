import json
import boto3
import uuid
import time
import os
import logging
from botocore.exceptions import ClientError

logger = logging.getLogger()
logger.setLevel(logging.INFO)

dynamodb = boto3.resource('dynamodb')
sqs = boto3.client('sqs')

TABLE_NAME = os.environ['DYNAMODB_TABLE']
QUEUE_URL = os.environ['SQS_QUEUE_URL']
RESERVATION_TTL_SECONDS = 600  # 10-minute hold


def lambda_handler(event, context):
    """
    Purchase API Lambda
    - Validates request
    - Atomically decrements inventory using DynamoDB conditional write
    - Queues payment for async processing via SQS
    - Returns immediate reservation confirmation
    """
    try:
        # Parse request body
        body = json.loads(event.get('body', '{}'))
        event_id = body.get('eventId')
        tier = body.get('tier')
        quantity = int(body.get('quantity', 1))
        idempotency_key = body.get('idempotencyKey', str(uuid.uuid4()))

        # Extract user from JWT (injected by Cognito authorizer)
        user_id = event.get('requestContext', {}).get('authorizer', {}).get('claims', {}).get('sub', 'anonymous')

        # --- Validate inputs ---
        if not event_id or not tier:
            return _response(400, {'error': 'eventId and tier are required'})
        if quantity < 1 or quantity > 8:
            return _response(400, {'error': 'Quantity must be between 1 and 8'})

        logger.info(f"Purchase attempt: user={user_id}, event={event_id}, tier={tier}, qty={quantity}")

        # --- Atomic inventory decrement (prevents overselling) ---
        table = dynamodb.Table(TABLE_NAME)
        reservation_id = str(uuid.uuid4())
        expires_at = int(time.time()) + RESERVATION_TTL_SECONDS

        try:
            table.update_item(
                Key={'EventID': event_id, 'Tier': tier},
                UpdateExpression='SET AvailableCount = AvailableCount - :dec',
                ConditionExpression='AvailableCount >= :qty',
                ExpressionAttributeValues={':dec': quantity, ':qty': quantity}
            )
        except ClientError as e:
            if e.response['Error']['Code'] == 'ConditionalCheckFailedException':
                logger.warning(f"Sold out: event={event_id}, tier={tier}")
                return _response(409, {'status': 'SOLD_OUT', 'message': 'No tickets available for this tier'})
            raise

        # --- Save reservation record with TTL ---
        table.put_item(
            Item={
                'EventID': f'RESERVATION#{reservation_id}',
                'Tier': tier,
                'ReservationID': reservation_id,
                'UserID': user_id,
                'Quantity': quantity,
                'Status': 'PENDING_PAYMENT',
                'IdempotencyKey': idempotency_key,
                'CreatedAt': int(time.time()),
                'ExpiresAt': expires_at,  # DynamoDB TTL attribute
                'TTL': expires_at
            }
        )

        # --- Queue payment for async processing ---
        sqs.send_message(
            QueueUrl=QUEUE_URL,
            MessageBody=json.dumps({
                'reservation_id': reservation_id,
                'user_id': user_id,
                'event_id': event_id,
                'tier': tier,
                'quantity': quantity,
                'idempotency_key': idempotency_key,
                'timestamp': int(time.time())
            }),
            MessageGroupId=event_id,           # FIFO ordering per event
            MessageDeduplicationId=idempotency_key
        )

        logger.info(f"Reservation created: id={reservation_id}, expires={expires_at}")

        return _response(200, {
            'status': 'RESERVED',
            'reservationId': reservation_id,
            'expiresIn': RESERVATION_TTL_SECONDS,
            'message': 'Tickets reserved. Complete payment within 10 minutes.'
        })

    except Exception as e:
        logger.error(f"Unexpected error: {str(e)}", exc_info=True)
        return _response(500, {'error': 'Internal server error. Please try again.'})


def _response(status_code, body):
    return {
        'statusCode': status_code,
        'headers': {
            'Content-Type': 'application/json',
            'Access-Control-Allow-Origin': '*'
        },
        'body': json.dumps(body)
    }
