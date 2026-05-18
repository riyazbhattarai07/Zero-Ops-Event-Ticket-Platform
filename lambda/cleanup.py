# ============================================================
# cleanup.py — Step 3: Release tickets when payment never comes
# ============================================================
# What this file does in plain English:
#   Sometimes a user reserves tickets but never pays.
#   (Maybe they closed the tab, their internet dropped, etc.)
#   Those tickets need to go back on sale — otherwise they're
#   stuck in limbo and nobody can buy them.
#
# This file runs in TWO ways:
#
#   Way 1 — DynamoDB Streams (fast, near-instant):
#     When a reservation's 10-minute TTL expires, DynamoDB
#     automatically deletes it and sends a "something was deleted"
#     event to this Lambda. We catch that and immediately
#     put the tickets back in inventory.
#
#   Way 2 — Scheduled (every 5 minutes, safety net):
#     DynamoDB TTL is "eventually consistent" — it usually works
#     instantly but in rare cases can lag up to 48 hours.
#     This scheduled scan catches anything that slipped through.
# ============================================================

import json
import boto3
import os
import time
import logging
from boto3.dynamodb.conditions import Attr
from botocore.exceptions import ClientError

logger = logging.getLogger()
logger.setLevel(logging.INFO)

# Connect to AWS services
dynamodb    = boto3.resource('dynamodb')
eventbridge = boto3.client('events')

# Config from Terraform
TABLE_NAME     = os.environ['DYNAMODB_TABLE']
EVENT_BUS_NAME = os.environ['EVENT_BUS_NAME']


# -------------------------------------------------------
# MAIN FUNCTION
# AWS calls this either from DynamoDB Streams or EventBridge scheduler
# We figure out which one triggered us and handle it accordingly
# -------------------------------------------------------
def lambda_handler(event, context):
    # Figure out who triggered us
    trigger = _detect_trigger(event)
    logger.info(f"Cleanup triggered by: {trigger}")

    if trigger == 'dynamodb_stream':
        return _handle_stream(event)     # Fast path: instant TTL expiry
    else:
        return _handle_scheduled_scan()  # Slow path: manual scan every 5 min


# -------------------------------------------------------
# Figure out what triggered this Lambda
# -------------------------------------------------------
def _detect_trigger(event):
    # DynamoDB stream events always have 'Records' with 'aws:dynamodb' source
    if 'Records' in event and event['Records'][0].get('eventSource') == 'aws:dynamodb':
        return 'dynamodb_stream'
    return 'scheduled'


# -------------------------------------------------------
# Handle DynamoDB Stream events
# This runs when DynamoDB TTL auto-deletes an expired reservation
# -------------------------------------------------------
def _handle_stream(event):
    recovered_tickets = 0
    table = dynamodb.Table(TABLE_NAME)

    for record in event.get('Records', []):

        # We only care about REMOVE events (TTL deletions)
        # INSERT and MODIFY are not our concern here
        if record['eventName'] != 'REMOVE':
            continue

        # DynamoDB streams give us the old data (before deletion)
        old = record.get('dynamodb', {}).get('OldImage', {})

        # Read the fields from the deleted record
        # DynamoDB streams use a special format: {'S': 'value'} for strings, {'N': '5'} for numbers
        status         = old.get('Status',        {}).get('S', '')
        event_id       = old.get('EventID',       {}).get('S', '')
        tier           = old.get('Tier',          {}).get('S', '')
        quantity       = int(old.get('Quantity',  {}).get('N', '0'))
        reservation_id = old.get('ReservationID', {}).get('S', '')

        # Only return inventory for PENDING_PAYMENT reservations
        # CONFIRMED = payment went through (tickets are legitimately sold)
        # FAILED    = already handled by payment.py
        if status != 'PENDING_PAYMENT':
            continue

        # Only process reservation records (not event inventory records)
        if not event_id.startswith('RESERVATION#'):
            continue

        # Strip the prefix to get the real event ID
        real_event_id = event_id.replace('RESERVATION#', '')

        logger.info(f"Expired reservation found — id: {reservation_id}, event: {real_event_id}, qty: {quantity}")

        # Put the tickets back on sale!
        _return_inventory(table, real_event_id, tier, quantity)

        # Let other services know a reservation expired (for analytics)
        _emit_event('ticket.reservation_expired', {
            'reservationId': reservation_id,
            'eventId':       real_event_id,
            'tier':          tier,
            'quantity':      quantity
        })

        recovered_tickets += quantity

    total_records = len(event.get('Records', []))
    logger.info(f"Stream cleanup done — recovered {recovered_tickets} tickets from {total_records} events")
    return {'source': 'stream', 'ticketsRecovered': recovered_tickets}


# -------------------------------------------------------
# Fallback: scan the whole table every 5 minutes
# Catches anything TTL missed
# -------------------------------------------------------
def _handle_scheduled_scan():
    table         = dynamodb.Table(TABLE_NAME)
    now           = int(time.time())   # Current Unix timestamp
    recovered     = 0
    scanned_count = 0

    try:
        # Find all reservations that:
        # 1. Are still marked as PENDING_PAYMENT (not paid yet)
        # 2. Have already expired (ExpiresAt is in the past)
        response = table.scan(
            FilterExpression=(
                Attr('Status').eq('PENDING_PAYMENT') &
                Attr('ExpiresAt').lt(now)
            ),
            ProjectionExpression='EventID, Tier, Quantity, ReservationID, ExpiresAt'
        )

        stale_reservations = response.get('Items', [])
        scanned_count      = len(stale_reservations)
        logger.info(f"Found {scanned_count} stale reservations to clean up")

        for item in stale_reservations:
            event_id       = item['EventID'].replace('RESERVATION#', '')  # Strip prefix
            tier           = item['Tier']
            quantity       = int(item.get('Quantity', 0))
            reservation_id = item.get('ReservationID', 'unknown')

            # Return tickets to inventory
            _return_inventory(table, event_id, tier, quantity)

            # Delete the stale reservation record manually
            table.delete_item(
                Key={'EventID': item['EventID'], 'Tier': tier}
            )

            # Notify analytics
            _emit_event('ticket.reservation_expired', {
                'reservationId': reservation_id,
                'eventId':       event_id,
                'tier':          tier,
                'quantity':      quantity,
                'cleanupMethod': 'scheduled_scan'  # So we know how it was cleaned up
            })

            recovered += quantity

    except Exception as e:
        logger.error(f"Scheduled scan error: {str(e)}", exc_info=True)
        raise

    logger.info(f"Scheduled cleanup done — scanned: {scanned_count}, recovered: {recovered} tickets")
    return {'source': 'scheduled', 'scanned': scanned_count, 'ticketsRecovered': recovered}


# -------------------------------------------------------
# Add tickets back to the available count in DynamoDB
# -------------------------------------------------------
def _return_inventory(table, event_id, tier, quantity):
    if quantity <= 0:
        return  # Nothing to return, skip
    try:
        table.update_item(
            Key={'EventID': event_id, 'Tier': tier},
            UpdateExpression='SET AvailableCount = AvailableCount + :qty, LastRecoveredAt = :ts',
            ExpressionAttributeValues={
                ':qty': quantity,
                ':ts':  int(time.time())
            }
        )
        logger.info(f"Tickets returned — event: {event_id}, tier: {tier}, qty: {quantity}")
    except ClientError as e:
        logger.error(f"Could not return inventory for {event_id}/{tier}: {str(e)}")


# -------------------------------------------------------
# Send a notification to EventBridge
# Other services listen to these and react automatically
# -------------------------------------------------------
def _emit_event(detail_type, detail):
    try:
        eventbridge.put_events(
            Entries=[{
                'Source':       'ticketing.cleanup',
                'DetailType':   detail_type,
                'Detail':       json.dumps(detail),
                'EventBusName': EVENT_BUS_NAME
            }]
        )
    except Exception as e:
        logger.error(f"EventBridge notification failed: {str(e)}")
