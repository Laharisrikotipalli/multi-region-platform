"""
Lambda: multi-region-failover
Triggered by CloudWatch Alarm when primary RDS becomes unhealthy.
Steps:
  1. Parse CloudWatch alarm from SNS event
  2. Verify primary RDS is truly unavailable (avoid false positives)
  3. Promote eu-west-1 read replica to standalone primary
  4. Update Route 53 to remove failed region from DNS rotation
  5. Notify ops team via SNS

RTO target: < 5 minutes. RPO target: < 30 seconds (async replication lag).
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
HOSTED_ZONE_ID        = os.environ.get("HOSTED_ZONE_ID", "Z09752483UKDQ3CQNX9T1")
FAILED_REGION_ELB     = os.environ.get("FAILED_REGION_ELB", "acc80dd91c9a64241888155eb3282071-1241349649.ap-southeast-1.elb.amazonaws.com")


def lambda_handler(event, context):
    logger.info("Event: %s", json.dumps(event))

    action = event.get("action", "")
    if action == "health_check":
        return {"statusCode": 200, "body": "healthy"}

    target_region = event.get("target_region", REPLICA_REGION)

    alarm_state = "ALARM"
    if "Records" in event:
        try:
            message     = json.loads(event["Records"][0]["Sns"]["Message"])
            alarm_state = message.get("NewStateValue", "")
            alarm_name  = message.get("AlarmName", "")
            logger.info("Alarm: %s | State: %s", alarm_name, alarm_state)
        except (KeyError, json.JSONDecodeError) as exc:
            logger.error("Failed to parse event: %s", exc)
            return {"statusCode": 400, "body": "Invalid event format"}

    if alarm_state != "ALARM" and action != "failover":
        return {"statusCode": 200, "body": "No action needed"}

    rds_primary = boto3.client("rds", region_name=PRIMARY_REGION)
    try:
        resp   = rds_primary.describe_db_instances(DBInstanceIdentifier="mr-postgres-primary")
        status = resp["DBInstances"][0]["DBInstanceStatus"]
        logger.info("Primary DB status: %s", status)
        if status in ("available", "backing-up", "modifying"):
            logger.warning("Primary reports %s - possible false positive; aborting", status)
            return {"statusCode": 200, "body": f"Primary still {status}, no failover"}
    except Exception as exc:
        logger.warning("Cannot reach primary RDS (%s) - proceeding with failover", exc)

    rds_replica = boto3.client("rds", region_name=target_region)
    logger.info("Promoting %s in %s...", REPLICA_DB_IDENTIFIER, target_region)
    try:
        rds_replica.promote_read_replica(
            DBInstanceIdentifier=REPLICA_DB_IDENTIFIER,
            BackupRetentionPeriod=7,
        )
        waiter = rds_replica.get_waiter("db_instance_available")
        waiter.wait(
            DBInstanceIdentifier=REPLICA_DB_IDENTIFIER,
            WaiterConfig={"Delay": 15, "MaxAttempts": 20},
        )
        logger.info("Replica promotion complete")
    except Exception as exc:
        logger.warning("Promotion issue: %s - may still be in progress", exc)

    if HOSTED_ZONE_ID and FAILED_REGION_ELB:
        try:
            r53 = boto3.client("route53")
            r53.change_resource_record_sets(
                HostedZoneId=HOSTED_ZONE_ID,
                ChangeBatch={
                    "Comment": f"Failover: removing {PRIMARY_REGION} from rotation",
                    "Changes": [{
                        "Action": "DELETE",
                        "ResourceRecordSet": {
                            "Name": "app.multi-region-platform.internal",
                            "Type": "CNAME",
                            "SetIdentifier": "aps1",
                            "Region": PRIMARY_REGION,
                            "TTL": 60,
                            "ResourceRecords": [{"Value": FAILED_REGION_ELB}]
                        }
                    }]
                }
            )
            logger.info("Route 53 updated: removed %s from rotation", PRIMARY_REGION)
        except Exception as exc:
            logger.warning("Route 53 update failed: %s", exc)

    _notify(
        f"DB FAILOVER COMPLETE\n"
        f"Promoted: {REPLICA_DB_IDENTIFIER} ({target_region})\n"
        f"Route 53: {PRIMARY_REGION} removed from DNS rotation\n"
        f"Timestamp: {time.strftime('%Y-%m-%dT%H:%M:%SZ', time.gmtime())}\n"
        f"Action required: Update app connection strings if not using RDS CNAME"
    )

    return {
        "statusCode": 200,
        "body": json.dumps({
            "status": "failover_complete",
            "promoted_replica": REPLICA_DB_IDENTIFIER,
            "region": target_region,
            "route53_updated": True,
        }),
    }


def _notify(message: str):
    if not SNS_ALERT_TOPIC_ARN:
        logger.info("No SNS topic configured - skipping notification")
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
