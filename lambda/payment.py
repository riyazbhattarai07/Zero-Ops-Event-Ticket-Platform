# ============================================================
# payment.py — Step 2: Process the actual payment
# ============================================================
# What this file does in plain English:
#   1. This runs AFTER purchase.py drops a message in SQS
#   2. SQS automatically triggers this Lambda with batches of payments
#   3. For each payment: we charge the user's card
#   4. If payment succeeds: mark the reservation as CONFIRMED
#   5. If payment fails: release the held tickets back to inventory
#   6. Either way: fire an event so other services (email, analytics) know what happened
#
# Why separate from purchase.py?
#   Payment APIs (Stripe, PayPal) can be slow (1-3 seconds).
#   If we put this in purchase.py, the user would wait 3 seconds.
#   By using a queue, the user gets an instant response and
#   payment happens quietly in the background.
# ============================================================

import json
import boto3
import os
import time
import logging
from botocore.exceptions import ClientError

logger = logging.getLogger()
logger.setLevel(logging.INFO)

# Connect to the AWS services we need
dynamodb    = boto3.resource('dynamodb')
eventbridge = boto3.client('events')      # For notifying other services
ses         = boto3.client('ses')         # For sending emails (not used directly here)

# Config from Terraform environment variables
TABLE_NAME     = os.environ['DYNAMODB_TABLE']
EVENT_BUS_NAME = os.environ['EVENT_BUS_NAME']
SES_SENDER     = os.environ.get('SES_SENDER_EMAIL', 'noreply@example.com')


# -------------------------------------------------------
# MAIN FUNCTION — SQS triggers this automatically
# 'event' contains a batch of messages from the queue
# Each message = one ticket purchase to process
# -------------------------------------------------------
def lambda_handler(event, context):
    results = []

    # Loop through each payment message in the batch
    for record in event.get('Records', []):
        reservation_id = None
        try:
            # Parse the message that purchase.py put in the queue
            message        = json.loads(record['body'])
            reservation_id = message['reservation_id']
            user_id        = message['user_id']
            event_id       = message['event_id']
            tier           = message['tier']
            quantity       = message['quantity']

            logger.info(f"Processing payment for reservation: {reservation_id}, user: {user_id}")

            table = dynamodb.Table(TABLE_NAME)

            # --- Safety check: don't process the same payment twice ---
            # SQS can sometimes deliver the same message more than once.
            # So we check if we already handled this reservation.
            existing = table.get_item(
                Key={'EventID': f'RESERVATION#{reservation_id}', 'Tier': tier}
            ).get('Item', {})

            if existing.get('Status') in ('CONFIRMED', 'FAILED'):
                logger.info(f"Already processed — skipping reservation: {reservation_id}")
                results.append({'reservationId': reservation_id, 'skipped': True})
                continue  # Skip to next message

            # --- Try to charge the user ---
            # Right now this is simulated (97% success rate like real payment processors)
            # To go live: replace _process_payment() with real Stripe SDK calls
            payment_result = _process_payment(user_id, quantity, event_id, tier)

            if payment_result['success']:
                # Payment went through! Mark as confirmed.
                table.update_item(
                    Key={'EventID': f'RESERVATION#{reservation_id}', 'Tier': tier},
                    UpdateExpression='SET #s = :status, PaymentID = :pid, ConfirmedAt = :ts',
                    ExpressionAttributeNames={'#s': 'Status'},   # 'Status' is a reserved word in DynamoDB
                    ExpressionAttributeValues={
                        ':status': 'CONFIRMED',
                        ':pid':    payment_result['payment_id'],  # Payment reference from Stripe/PayPal
                        ':ts':     int(time.time())
                    }
                )

                # Tell the rest of the system: "a ticket was just purchased!"
                # This triggers email confirmation, analytics, etc.
                _emit_event('ticket.purchased', {
                    'reservationId': reservation_id,
                    'userId':        user_id,
                    'eventId':       event_id,
                    'tier':          tier,
                    'quantity':      quantity,
                    'paymentId':     payment_result['payment_id']
                })

                logger.info(f"Payment confirmed — reservation: {reservation_id}, payment: {payment_result['payment_id']}")
                results.append({'reservationId': reservation_id, 'status': 'CONFIRMED'})

            else:
                # Payment failed — we need to give the tickets back!
                # Otherwise those tickets would be stuck in limbo forever.
                _return_inventory(table, event_id, tier, quantity)

                # Mark the reservation as failed
                table.update_item(
                    Key={'EventID': f'RESERVATION#{reservation_id}', 'Tier': tier},
                    UpdateExpression='SET #s = :status, FailureReason = :reason, FailedAt = :ts',
                    ExpressionAttributeNames={'#s': 'Status'},
                    ExpressionAttributeValues={
                        ':status': 'FAILED',
                        ':reason': payment_result.get('error', 'Unknown error'),
                        ':ts':     int(time.time())
                    }
                )

                # Tell the system the payment failed (so we can notify the user)
                _emit_event('ticket.payment_failed', {
                    'reservationId': reservation_id,
                    'userId':        user_id,
                    'eventId':       event_id,
                    'reason':        payment_result.get('error')
                })

                logger.warning(f"Payment failed — reservation: {reservation_id}, reason: {payment_result.get('error')}")
                results.append({'reservationId': reservation_id, 'status': 'FAILED'})

        except Exception as e:
            logger.error(f"Error processing {reservation_id}: {str(e)}", exc_info=True)
            # Re-raise the error so SQS retries this message (up to 3 times)
            raise

    return {'processedRecords': len(results), 'results': results}


# -------------------------------------------------------
# Simulated payment gateway
# In production: replace this with real Stripe SDK code
# (see the comment inside for the exact Stripe code to use)
# -------------------------------------------------------
def _process_payment(user_id, quantity, event_id, tier):
    """
    TO GO LIVE with Stripe, replace this entire function with:

        import stripe
        stripe.api_key = os.environ['STRIPE_SECRET_KEY']
        charge = stripe.Charge.create(
            amount=quantity * 5000,        # $50.00 per ticket, in cents
            currency='usd',
            source='tok_visa',             # Token from frontend Stripe.js
            description=f'{event_id} / {tier}'
        )
        return {'success': True, 'payment_id': charge['id']}
    """
    import uuid
    import random

    # Simulate real-world payment: 97% of payments go through,
    # 3% fail (declined cards, expired cards, etc.)
    if random.random() < 0.97:
        return {'success': True, 'payment_id': f'pay_{uuid.uuid4().hex[:16]}'}
    else:
        return {'success': False, 'error': 'Card declined'}


# -------------------------------------------------------
# Give tickets back to inventory when payment fails
# -------------------------------------------------------
def _return_inventory(table, event_id, tier, quantity):
    try:
        # Add the quantity back — undoes what purchase.py subtracted
        table.update_item(
            Key={'EventID': event_id, 'Tier': tier},
            UpdateExpression='SET AvailableCount = AvailableCount + :qty',
            ExpressionAttributeValues={':qty': quantity}
        )
        logger.info(f"Tickets returned — event: {event_id}, tier: {tier}, qty: {quantity}")
    except ClientError as e:
        logger.error(f"Failed to return inventory: {str(e)}")


# -------------------------------------------------------
# Send a notification to EventBridge
# Other services (SES email, analytics) listen for these events
# and react automatically — they don't need to be called directly
# -------------------------------------------------------
def _emit_event(detail_type, detail):
    try:
        eventbridge.put_events(
            Entries=[{
                'Source':      'ticketing.platform',   # Who is sending this event
                'DetailType':  detail_type,            # What happened (e.g. 'ticket.purchased')
                'Detail':      json.dumps(detail),     # The data about what happened
                'EventBusName': EVENT_BUS_NAME
            }]
        )
    except Exception as e:
        # Don't crash the payment if EventBridge fails — just log it
        logger.error(f"EventBridge notification failed: {str(e)}")
