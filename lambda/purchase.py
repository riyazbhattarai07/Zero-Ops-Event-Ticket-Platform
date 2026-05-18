import json
import boto3
import os
import uuid

# Connect to AWS services simply
dynamodb = boto3.resource('dynamodb')
sqs = boto3.client('sqs')

TABLE_NAME = os.environ['DYNAMODB_TABLE']
QUEUE_URL  = os.environ['SQS_QUEUE_URL']

def lambda_handler(event, context):
    """
    This function handles the initial ticket reservation.
    It checks if tickets are left, subtracts them, creates a 10-minute hold,
    and drops a message into the SQS queue for processing payment.
    """
    # Parse what the user sent us
    body = json.loads(event.get('body', '{}'))
    event_id = body.get('eventId')
    tier = body.get('tier')
    quantity = int(body.get('quantity', 1))
    
    table = dynamodb.Table(TABLE_NAME)
    reservation_id = str(uuid.uuid4())
    
    
    try:
        # Try to subtract tickets from the inventory table
        # It will fail if AvailableCount is less than the requested quantity
        table.update_item(
            Key={'EventID': event_id, 'Tier': tier},
            UpdateExpression='SET AvailableCount = AvailableCount - :qty',
            ConditionExpression='AvailableCount >= :qty',
            ExpressionAttributeValues={':qty': quantity}
        )
        
    except Exception:
        # If the condition above fails, it means tickets are sold out
        print(f"Sold out or error for event: {event_id}")
        return {
            'statusCode': 409,
            'body': json.dumps({'status': 'SOLD_OUT', 'message': 'No tickets left!'})
        }

    # Create a temporary reservation record with a 10-minute status window
    table.put_item(
        Item={
            'EventID': f'RESERVATION#{reservation_id}',
            'Tier': tier,
            'ReservationID': reservation_id,
            'Quantity': quantity,
            'Status': 'PENDING_PAYMENT'
        }
    )

    # Send a message to the SQS queue so payment processing can handle it next
    sqs.send_message(
        QueueUrl=QUEUE_URL,
        MessageBody=json.dumps({
            'reservation_id': reservation_id,
            'event_id': event_id,
            'tier': tier,
            'quantity': quantity
        }),
        MessageGroupId=event_id,
        MessageDeduplicationId=reservation_id
    )

    # Respond to the user immediately that their hold is secure
    return {
        'statusCode': 200,
        'body': json.dumps({
            'status': 'RESERVED',
            'reservationId': reservation_id,
            'message': 'Tickets held! Please complete your payment.'
        })
    }