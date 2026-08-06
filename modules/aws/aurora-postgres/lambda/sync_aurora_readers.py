import json
import os
import socket

import boto3


rds = boto3.client("rds")
elbv2 = boto3.client("elbv2")


def _writer_ips(cluster_identifier: str, port: int) -> set[str]:
    cluster = rds.describe_db_clusters(
        DBClusterIdentifier=cluster_identifier
    )["DBClusters"][0]
    writers = [
        member["DBInstanceIdentifier"]
        for member in cluster["DBClusterMembers"]
        if member["IsClusterWriter"]
    ]

    # Keep the existing healthy target if Aurora is temporarily unable to
    # identify exactly one writer during a failover transition.
    if len(writers) != 1:
        raise RuntimeError(
            f"Expected exactly one Aurora writer, found {len(writers)}"
        )

    addresses: set[str] = set()
    for identifier in writers:
        instance = rds.describe_db_instances(
            DBInstanceIdentifier=identifier
        )["DBInstances"][0]
        hostname = instance["Endpoint"]["Address"]
        for result in socket.getaddrinfo(
            hostname, port, family=socket.AF_INET, type=socket.SOCK_STREAM
        ):
            addresses.add(result[4][0])
    return addresses


def handler(event, context):
    cluster_identifier = os.environ["CLUSTER_IDENTIFIER"]
    target_group_arn = os.environ["TARGET_GROUP_ARN"]
    port = int(os.environ.get("PORT", "5432"))

    desired = _writer_ips(cluster_identifier, port)
    health = elbv2.describe_target_health(TargetGroupArn=target_group_arn)
    current = {
        item["Target"]["Id"]
        for item in health["TargetHealthDescriptions"]
    }

    stale = current - desired
    missing = desired - current

    if stale:
        elbv2.deregister_targets(
            TargetGroupArn=target_group_arn,
            Targets=[{"Id": ip, "Port": port} for ip in sorted(stale)],
        )
    if missing:
        elbv2.register_targets(
            TargetGroupArn=target_group_arn,
            Targets=[{"Id": ip, "Port": port} for ip in sorted(missing)],
        )

    result = {
        "cluster_identifier": cluster_identifier,
        "desired_writer_ips": sorted(desired),
        "registered": sorted(missing),
        "deregistered": sorted(stale),
    }
    print(json.dumps(result))
    return result
