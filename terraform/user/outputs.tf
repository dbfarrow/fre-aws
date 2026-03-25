output "instance_id" {
  description = "EC2 instance ID for this user."
  value       = module.user_ec2.id
}

output "instance_state" {
  description = "Current EC2 instance state for this user."
  value       = module.user_ec2.instance_state
}

output "instance_ami" {
  description = "AMI ID of the current EC2 instance. Read by up.sh to pin the AMI and prevent unintended instance replacement when Amazon publishes a new AMI."
  value       = module.user_ec2.ami
}
