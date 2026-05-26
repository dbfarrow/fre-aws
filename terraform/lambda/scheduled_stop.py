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
    instances = [i for r in resp['Reservations'] for i in r['Instances']]
    if not instances:
        logger.info(f"No running instances for project '{project}'")
        return {'hibernated': [], 'stopped': []}

    hibernate_ids = [
        i['InstanceId'] for i in instances
        if i.get('HibernationOptions', {}).get('Configured', False)
    ]
    stop_ids = [
        i['InstanceId'] for i in instances
        if not i.get('HibernationOptions', {}).get('Configured', False)
    ]

    if hibernate_ids:
        logger.info(f"Hibernating {len(hibernate_ids)} instances: {hibernate_ids}")
        ec2.stop_instances(InstanceIds=hibernate_ids, Hibernate=True)

    if stop_ids:
        logger.info(f"Stopping {len(stop_ids)} instances: {stop_ids}")
        ec2.stop_instances(InstanceIds=stop_ids)

    return {'hibernated': hibernate_ids, 'stopped': stop_ids}
