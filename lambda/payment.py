import json
import boto3
import os
import time
import logging
from botocore.exceptions import ClientError

logger = logging.getLogger()
logger.setLevel(logging.INFO)

dynamodb = boto3.resource('dynamodb')
eventbridge = boto3.client('events')
ses = boto3.client('ses')

TABLE_NAME = os.environ['DYNAMODB_TABLE']
EVENT_BUS_NAME = os.environ['EVENT_BUS_NAME']
SES_SENDER = os.environ.get('SES_SENDER_EMAIL', 'noreply@example.com')


def lambda_handler(event, context):
    """
    Payment Processor Lambda (triggered by SQS)
    - Processes each payment message from SQS queue
    - Simulates payment gateway call (replace with real Stripe/PayPal SDK)
    - Updates reservation status in DynamoDB
    - Emits EventBridge event to trigger downstream services (SES email, analytics)
    - Failed payments return inventory and expire reservation
    """
    results = []

    for record in event.get('Records', []):
        reservation_id = None
        try:
            message = json.loads(record['body'])
            reservation_id = message['reservation_id']
            user_id = message['user_id']
            event_id = message['event_id']
            tier = message['tier']
            quantity = message['quantity']

            logger.info(f"Processing payment: reservation={reservation_id}, user={user_id}")

            table = dynamodb.Table(TABLE_NAME)

            # --- Idempotency check: skip if already processed ---
            existing = table.get_item(
                Key={'EventID': f'RESERVATION#{reservation_id}', 'Tier': tier}
            ).get('Item', {})

            if existing.get('Status') in ('CONFIRMED', 'FAILED'):
                logger.info(f"Skipping already-processed reservation: {reservation_id}")
                results.append({'reservationId': reservation_id, 'skipped': True})
                continue

            # --- Simulate payment gateway (replace with Stripe SDK) ---
            payment_result = _process_payment(user_id, quantity, event_id, tier)

            if payment_result['success']:
                # Mark reservation as confirmed
                table.update_item(
                    Key={'EventID': f'RESERVATION#{reservation_id}', 'Tier': tier},
                    UpdateExpression='SET #s = :status, PaymentID = :pid, ConfirmedAt = :ts',
                    ExpressionAttributeNames={'#s': 'Status'},
                    ExpressionAttributeValues={
                        ':status': 'CONFIRMED',
                        ':pid': payment_result['payment_id'],
                        ':ts': int(time.time())
                    }
                )

                # Emit event for downstream services (SES, analytics, fraud detection)
                _emit_event('ticket.purchased', {
                    'reservationId': reservation_id,
                    'userId': user_id,
                    'eventId': event_id,
                    'tier': tier,
                    'quantity': quantity,
                    'paymentId': payment_result['payment_id']
                })

                logger.info(f"Payment confirmed: reservation={reservation_id}, payment={payment_result['payment_id']}")
                results.append({'reservationId': reservation_id, 'status': 'CONFIRMED'})

            else:
                # Payment failed: return inventory
                _return_inventory(table, event_id, tier, quantity)

                table.update_item(
                    Key={'EventID': f'RESERVATION#{reservation_id}', 'Tier': tier},
                    UpdateExpression='SET #s = :status, FailureReason = :reason, FailedAt = :ts',
                    ExpressionAttributeNames={'#s': 'Status'},
                    ExpressionAttributeValues={
                        ':status': 'FAILED',
                        ':reason': payment_result.get('error', 'Unknown'),
                        ':ts': int(time.time())
                    }
                )

                _emit_event('ticket.payment_failed', {
                    'reservationId': reservation_id,
                    'userId': user_id,
                    'eventId': event_id,
                    'reason': payment_result.get('error')
                })

                logger.warning(f"Payment failed: reservation={reservation_id}, reason={payment_result.get('error')}")
                results.append({'reservationId': reservation_id, 'status': 'FAILED'})

        except Exception as e:
            logger.error(f"Error processing reservation {reservation_id}: {str(e)}", exc_info=True)
            # Re-raise to let SQS retry the message
            raise

    return {'processedRecords': len(results), 'results': results}


def _process_payment(user_id, quantity, event_id, tier):
    """
    Simulated payment gateway.
    Replace this with actual Stripe or PayPal SDK calls.

    Example Stripe integration:
        import stripe
        stripe.api_key = os.environ['STRIPE_SECRET_KEY']
        charge = stripe.Charge.create(
            amount=quantity * 5000,  # $50.00 per ticket in cents
            currency='usd',
            source='tok_visa',       # From frontend Stripe.js token
            description=f'Ticket: {event_id} / {tier}'
        )
        return {'success': True, 'payment_id': charge['id']}
    """
    import uuid
    # Simulate 97% success rate (realistic for payment processors)
    import random
    if random.random() < 0.97:
        return {'success': True, 'payment_id': f'pay_{uuid.uuid4().hex[:16]}'}
    else:
        return {'success': False, 'error': 'Card declined'}


def _return_inventory(table, event_id, tier, quantity):
    """Return inventory when payment fails."""
    try:
        table.update_item(
            Key={'EventID': event_id, 'Tier': tier},
            UpdateExpression='SET AvailableCount = AvailableCount + :qty',
            ExpressionAttributeValues={':qty': quantity}
        )
        logger.info(f"Inventory returned: event={event_id}, tier={tier}, qty={quantity}")
    except ClientError as e:
        logger.error(f"Failed to return inventory: {str(e)}")


def _emit_event(detail_type, detail):
    """Publish event to EventBridge for downstream consumers."""
    try:
        eventbridge.put_events(
            Entries=[{
                'Source': 'ticketing.platform',
                'DetailType': detail_type,
                'Detail': json.dumps(detail),
                'EventBusName': EVENT_BUS_NAME
            }]
        )
    except Exception as e:
        logger.error(f"EventBridge publish failed: {str(e)}")
