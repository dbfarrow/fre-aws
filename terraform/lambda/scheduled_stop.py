import boto3
import os
import logging

logger = logging.getLogger()
logger.setLevel(logging.INFO)


def handler(event, context):
    ec2 = boto3.client('ec2')
    project = os.environ['PROJECT_NAME']
    resp = ec2.describe_instances(Filters=[
        {'Name': 'tag:ProjectName', 'Values': [project]},
        {'Name': 'instance-state-name', 'Values': ['running', 'pending']}
    ])
    ids = [i['InstanceId'] for r in resp['Reservations'] for i in r['Instances']]
    if not ids:
        logger.info(f"No running instances for project '{project}'")
        return {'stopped': []}
    logger.info(f"Stopping {len(ids)} instances: {ids}")
    ec2.stop_instances(InstanceIds=ids)
    return {'stopped': ids}
