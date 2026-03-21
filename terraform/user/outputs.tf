output "instance_id" {
  description = "EC2 instance ID for this user."
  value       = module.user_ec2.id
}

output "instance_state" {
  description = "Current EC2 instance state for this user."
  value       = module.user_ec2.instance_state
}
