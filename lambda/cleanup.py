import json
import boto3
import os
import time
import logging
from boto3.dynamodb.conditions import Key, Attr
from botocore.exceptions import ClientError

logger = logging.getLogger()
logger.setLevel(logging.INFO)

dynamodb = boto3.resource('dynamodb')
eventbridge = boto3.client('events')

TABLE_NAME = os.environ['DYNAMODB_TABLE']
EVENT_BUS_NAME = os.environ['EVENT_BUS_NAME']


def lambda_handler(event, context):
    """
    Cleanup Lambda - triggered two ways:

    1. DynamoDB Streams (primary): When DynamoDB TTL auto-expires a reservation,
       a stream event fires this Lambda to return inventory immediately.
       This gives sub-second inventory recovery on expiration.

    2. EventBridge Scheduled Rule (fallback): Runs every 5 minutes to catch
       any reservations that slipped through TTL (DynamoDB TTL is eventually
       consistent and can lag up to 48 hours in rare cases).
    """
    source = _detect_trigger_source(event)
    logger.info(f"Cleanup triggered by: {source}")

    if source == 'dynamodb_stream':
        return _handle_stream_events(event)
    else:
        return _handle_scheduled_scan()


def _detect_trigger_source(event):
    if 'Records' in event and event['Records'][0].get('eventSource') == 'aws:dynamodb':
        return 'dynamodb_stream'
    return 'scheduled'


def _handle_stream_events(event):
    """Handle DynamoDB stream events (TTL expirations)."""
    recovered = 0
    table = dynamodb.Table(TABLE_NAME)

    for record in event.get('Records', []):
        # Only process REMOVE events (TTL expiration or manual delete)
        if record['eventName'] != 'REMOVE':
            continue

        old_image = record.get('dynamodb', {}).get('OldImage', {})
        status = old_image.get('Status', {}).get('S', '')
        event_id = old_image.get('EventID', {}).get('S', '')
        tier = old_image.get('Tier', {}).get('S', '')
        quantity = int(old_image.get('Quantity', {}).get('N', '0'))
        reservation_id = old_image.get('ReservationID', {}).get('S', '')

        # Only return inventory for PENDING_PAYMENT reservations
        # (CONFIRMED and FAILED are already handled)
        if status != 'PENDING_PAYMENT':
            continue

        if not event_id.startswith('RESERVATION#'):
            continue

        real_event_id = event_id.replace('RESERVATION#', '')

        logger.info(f"Expired reservation detected: id={reservation_id}, event={real_event_id}, tier={tier}, qty={quantity}")

        # Return inventory
        _return_inventory(table, real_event_id, tier, quantity)

        # Emit expiry event for analytics
        _emit_event('ticket.reservation_expired', {
            'reservationId': reservation_id,
            'eventId': real_event_id,
            'tier': tier,
            'quantity': quantity
        })

        recovered += quantity

    logger.info(f"Stream cleanup: recovered {recovered} tickets from {len(event.get('Records', []))} events")
    return {'source': 'stream', 'ticketsRecovered': recovered}


def _handle_scheduled_scan():
    """Fallback: scan for expired PENDING_PAYMENT reservations."""
    table = dynamodb.Table(TABLE_NAME)
    now = int(time.time())
    recovered = 0
    scanned = 0

    # Scan for stale reservations (TTL should handle most, this is a safety net)
    # In production, add a GSI on Status+ExpiresAt for efficient querying
    try:
        response = table.scan(
            FilterExpression=Attr('Status').eq('PENDING_PAYMENT') & Attr('ExpiresAt').lt(now),
            ProjectionExpression='EventID, Tier, Quantity, ReservationID, ExpiresAt'
        )

        items = response.get('Items', [])
        scanned = len(items)
        logger.info(f"Scheduled scan found {scanned} stale reservations")

        for item in items:
            event_id = item['EventID'].replace('RESERVATION#', '')
            tier = item['Tier']
            quantity = int(item.get('Quantity', 0))
            reservation_id = item.get('ReservationID', 'unknown')

            _return_inventory(table, event_id, tier, quantity)

            # Delete the stale reservation record
            table.delete_item(
                Key={'EventID': item['EventID'], 'Tier': tier}
            )

            _emit_event('ticket.reservation_expired', {
                'reservationId': reservation_id,
                'eventId': event_id,
                'tier': tier,
                'quantity': quantity,
                'cleanupMethod': 'scheduled_scan'
            })

            recovered += quantity

    except Exception as e:
        logger.error(f"Scheduled scan error: {str(e)}", exc_info=True)
        raise

    logger.info(f"Scheduled cleanup complete: scanned={scanned}, recovered={recovered} tickets")
    return {'source': 'scheduled', 'scanned': scanned, 'ticketsRecovered': recovered}


def _return_inventory(table, event_id, tier, quantity):
    """Atomically return inventory to the event tier."""
    if quantity <= 0:
        return
    try:
        table.update_item(
            Key={'EventID': event_id, 'Tier': tier},
            UpdateExpression='SET AvailableCount = AvailableCount + :qty, LastRecoveredAt = :ts',
            ExpressionAttributeValues={':qty': quantity, ':ts': int(time.time())}
        )
        logger.info(f"Inventory returned: event={event_id}, tier={tier}, qty={quantity}")
    except ClientError as e:
        logger.error(f"Failed to return inventory for {event_id}/{tier}: {str(e)}")


def _emit_event(detail_type, detail):
    """Publish cleanup event to EventBridge."""
    try:
        eventbridge.put_events(
            Entries=[{
                'Source': 'ticketing.cleanup',
                'DetailType': detail_type,
                'Detail': json.dumps(detail),
                'EventBusName': EVENT_BUS_NAME
            }]
        )
    except Exception as e:
        logger.error(f"EventBridge publish failed: {str(e)}")
