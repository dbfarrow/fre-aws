output "instance_id" {
  description = "EC2 instance ID — used by start.sh, stop.sh, and connect.sh."
  value       = module.ec2.id
}

output "instance_state" {
  description = "Current EC2 instance state."
  value       = module.ec2.instance_state
}

output "private_ip" {
  description = "Private IP address of the EC2 instance."
  value       = module.ec2.private_ip
}

output "public_ip" {
  description = "Public IP address (only set when network_mode = 'public')."
  value       = module.ec2.public_ip
  # Will be null/empty for private subnet deployments
}

output "connect_command" {
  description = "Run this command to open a shell on your dev instance."
  value       = "aws ssm start-session --target ${module.ec2.id} --region ${var.aws_region} --profile ${var.aws_profile}"
}

output "vpc_id" {
  description = "VPC ID."
  value       = module.vpc.vpc_id
}

output "network_mode" {
  description = "Active network mode."
  value       = var.network_mode
}
