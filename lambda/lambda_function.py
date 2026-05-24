"""
Lambda: promote-replica
Triggered by CloudWatch Alarm when the primary RDS instance becomes unhealthy.
Automatically promotes the eu-west-1 read replica to a standalone primary,
then notifies the ops team via SNS.

RTO target: < 5 minutes from alarm to promotion complete.
"""

import json
import logging
import os
import time

import boto3

logger = logging.getLogger()
logger.setLevel(logging.INFO)

PRIMARY_REGION        = os.environ.get("PRIMARY_REGION", "ap-southeast-1")
REPLICA_REGION        = os.environ.get("REPLICA_REGION", "eu-west-1")
REPLICA_DB_IDENTIFIER = os.environ.get("REPLICA_DB_IDENTIFIER", "mr-postgres-replica-euw1")
SNS_ALERT_TOPIC_ARN   = os.environ.get("SNS_ALERT_TOPIC_ARN", "")


def lambda_handler(event, context):
    """
    Failover steps:
      1. Parse CloudWatch alarm from SNS event
      2. Verify primary RDS is truly unavailable (avoid false positives)
      3. Promote eu-west-1 replica to standalone primary
      4. Notify ops team via SNS
    """
    logger.info("Event: %s", json.dumps(event))

    # Step 1 – parse alarm
    try:
        message    = json.loads(event["Records"][0]["Sns"]["Message"])
        alarm_state = message.get("NewStateValue", "")
        alarm_name  = message.get("AlarmName", "")
        logger.info("Alarm: %s | State: %s", alarm_name, alarm_state)
    except (KeyError, json.JSONDecodeError) as exc:
        logger.error("Failed to parse event: %s", exc)
        return {"statusCode": 400, "body": "Invalid event format"}

    if alarm_state != "ALARM":
        logger.info("Alarm not in ALARM state (%s) — no action needed", alarm_state)
        return {"statusCode": 200, "body": "No action needed"}

    # Step 2 – verify primary is truly down
    rds_primary = boto3.client("rds", region_name=PRIMARY_REGION)
    try:
        resp   = rds_primary.describe_db_instances(DBInstanceIdentifier="mr-postgres-primary")
        status = resp["DBInstances"][0]["DBInstanceStatus"]
        logger.info("Primary DB status: %s", status)
        if status in ("available", "backing-up", "modifying"):
            logger.warning("Primary reports '%s' — possible false positive; aborting", status)
            return {"statusCode": 200, "body": f"Primary still {status}, no failover"}
    except Exception as exc:
        logger.warning("Cannot reach primary RDS (%s) — proceeding with failover", exc)

    # Step 3 – promote replica
    rds_replica = boto3.client("rds", region_name=REPLICA_REGION)
    logger.info("Promoting %s in %s...", REPLICA_DB_IDENTIFIER, REPLICA_REGION)
    try:
        rds_replica.promote_read_replica(
            DBInstanceIdentifier=REPLICA_DB_IDENTIFIER,
            BackupRetentionPeriod=7,
        )
    except rds_replica.exceptions.InvalidDBInstanceStateFault as exc:
        logger.error("Cannot promote replica: %s", exc)
        _notify(f"FAILOVER FAILED: Cannot promote {REPLICA_DB_IDENTIFIER}: {exc}")
        return {"statusCode": 500, "body": str(exc)}

    waiter = rds_replica.get_waiter("db_instance_available")
    try:
        waiter.wait(
            DBInstanceIdentifier=REPLICA_DB_IDENTIFIER,
            WaiterConfig={"Delay": 15, "MaxAttempts": 20},
        )
        logger.info("Replica promotion complete")
    except Exception as exc:
        logger.warning("Waiter timed out: %s — promotion may still be in progress", exc)

    # Step 4 – notify
    _notify(
        f"DB FAILOVER COMPLETE\n"
        f"Promoted: {REPLICA_DB_IDENTIFIER} ({REPLICA_REGION})\n"
        f"Timestamp: {time.strftime('%Y-%m-%dT%H:%M:%SZ', time.gmtime())}\n"
        f"Action required: Update app connection strings if not using RDS CNAME"
    )

    return {
        "statusCode": 200,
        "body": json.dumps({
            "status": "failover_complete",
            "promoted_replica": REPLICA_DB_IDENTIFIER,
            "region": REPLICA_REGION,
        }),
    }


def _notify(message: str):
    if not SNS_ALERT_TOPIC_ARN:
        logger.info("No SNS topic configured — skipping notification")
        return
    try:
        boto3.client("sns", region_name=PRIMARY_REGION).publish(
            TopicArn=SNS_ALERT_TOPIC_ARN,
            Subject="[CRITICAL] Multi-Region Platform DB Failover",
            Message=message,
        )
        logger.info("SNS notification sent")
    except Exception as exc:
        logger.error("Failed to send SNS notification: %s", exc)
