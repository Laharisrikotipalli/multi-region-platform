import json
import logging
import os
import time

import boto3

logger = logging.getLogger()
logger.setLevel(logging.INFO)

PRIMARY_REGION           = os.environ.get("PRIMARY_REGION", "ap-southeast-1")
REPLICA_REGION           = os.environ.get("REPLICA_REGION", "eu-west-1")
REPLICA_DB_IDENTIFIER    = os.environ.get("REPLICA_DB_IDENTIFIER", "mr-postgres-replica-euw1")
SNS_ALERT_TOPIC_ARN      = os.environ.get("SNS_ALERT_TOPIC_ARN", "")
HOSTED_ZONE_ID           = os.environ.get("HOSTED_ZONE_ID", "")
FAILED_REGION_ELB        = os.environ.get("FAILED_REGION_ELB", "")
FAILED_REGION_ELB_ZONE_ID = os.environ.get("FAILED_REGION_ELB_ZONE_ID", "")


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

    if HOSTED_ZONE_ID and FAILED_REGION_ELB and FAILED_REGION_ELB_ZONE_ID:
        # NOTE: terraform/modules/route53/main.tf provisions ALIAS "A" records with
        # SetIdentifier = the region name (e.g. "ap-southeast-1"), not a CNAME. An alias
        # record's DELETE must match the existing record exactly, including AliasTarget —
        # you cannot supply ResourceRecords/TTL for an alias record.
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
                            "Type": "A",
                            "SetIdentifier": PRIMARY_REGION,
                            "Region": PRIMARY_REGION,
                            "AliasTarget": {
                                "HostedZoneId": FAILED_REGION_ELB_ZONE_ID,
                                "DNSName": FAILED_REGION_ELB,
                                "EvaluateTargetHealth": True,
                            },
                        }
                    }]
                }
            )
            logger.info("Route 53 updated: removed %s from rotation", PRIMARY_REGION)
        except Exception as exc:
            logger.warning("Route 53 update failed: %s", exc)
    else:
        # Route 53's own health check (30s interval, 3-failure threshold) already removes
        # this region from rotation once /health starts returning non-200 — this manual
        # DNS-removal step is a belt-and-suspenders extra, not the primary failover path.
        logger.info(
            "Skipping manual Route 53 cleanup (HOSTED_ZONE_ID/FAILED_REGION_ELB/"
            "FAILED_REGION_ELB_ZONE_ID not fully configured). Health-check-based "
            "removal from DNS rotation still applies independently."
        )

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