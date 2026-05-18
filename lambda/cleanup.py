import json
import boto3
import os


# Connect to AWS services simply
dynamodb = boto3.resource('dynamodb')
TABLE_NAME = os.environ['DYNAMODB_TABLE']

def lambda_handler(event, context):
    """
    This function cleans up ticket holds that have expired 
    so other users can buy them.
    """
    table = dynamodb.Table(TABLE_NAME)
    
    # Loop through the records sent to this Lambda function from the DynamoDB Stream
    for record in event.get('Records', []):
        
        # We only care if a record was DELETED (expired) from the database
        if record['eventName'] == 'REMOVE':
            
            # Extract the old data from the deleted record
            old_data = record['dynamodb'].get('OldImage', {})
            
            # Extract basic strings and numbers from the special DynamoDB format
            status = old_data.get('Status', {}).get('S', '')
            event_id = old_data.get('EventID', {}).get('S', '')
            tier = old_data.get('Tier', {}).get('S', '')
            quantity = int(old_data.get('Quantity', {}).get('N', '0'))
            
            # Only put tickets back if the user failed to complete the payment
            if status == "PENDING_PAYMENT" and event_id.startswith('RESERVATION#'):
                
                # Strip the prefix to get the real event ID name
                real_event_id = event_id.replace('RESERVATION#', '')
                print(f"Hold expired for {real_event_id}. Returning {quantity} tickets.")
                
                # Update the main event table to add the tickets back to available inventory
                table.update_item(
                    Key={'EventID': real_event_id, 'Tier': tier},
                    UpdateExpression='SET AvailableCount = AvailableCount + :qty',
                    ExpressionAttributeValues={':qty': quantity}
                )
                
    return {"statusCode": 200, "body": "Cleanup completed successfully"}