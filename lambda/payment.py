import json
import boto3
import os

# Connect to AWS services simply
dynamodb = boto3.resource('dynamodb')
TABLE_NAME = os.environ['DYNAMODB_TABLE']

def lambda_handler(event, context):
    """
    This function processes payments from the SQS queue.
    If payment succeeds, it confirms the ticket.
    If payment fails, it puts the ticket back on sale.
    """
    table = dynamodb.Table(TABLE_NAME)
    
    # Loop through each message sent to this Lambda from the SQS queue
    for record in event.get('Records', []):
        
        # Read the message body details
        body = json.loads(record['body'])
        reservation_id = body['reservation_id']
        event_id = body['event_id']
        tier = body['tier']
        quantity = body['quantity']
        
        print(f"Processing payment for reservation: {reservation_id}")
        
        # Simulate charging a credit card (97% success rate for real-world simulation)
        # In a production app, this is where a Stripe API call would go
        import random
        payment_success = random.random() < 0.97
        
        if payment_success:
            print(f"Payment successful for {reservation_id}! Confirming seat.")
            
            # Update the reservation record status to CONFIRMED in the database
            table.update_item(
                Key={'EventID': f'RESERVATION#{reservation_id}', 'Tier': tier},
                UpdateExpression='SET #s = :status',
                ExpressionAttributeNames={'#s': 'Status'},
                ExpressionAttributeValues={':status': 'CONFIRMED'}
            )
            
        else:
            print(f"Payment failed for {reservation_id}. Releasing inventory.")
            
            # Mark the reservation record status as FAILED in the database
            table.update_item(
                Key={'EventID': f'RESERVATION#{reservation_id}', 'Tier': tier},
                UpdateExpression='SET #s = :status',
                ExpressionAttributeNames={'#s': 'Status'},
                ExpressionAttributeValues={':status': 'FAILED'}
            )
            
            # Put the tickets back into the available pool so someone else can buy them
            table.update_item(
                Key={'EventID': event_id, 'Tier': tier},
                UpdateExpression='SET AvailableCount = AvailableCount + :qty',
                ExpressionAttributeValues={':qty': quantity}
            )
            
    return {"statusCode": 200, "body": "Payment processing completed"}