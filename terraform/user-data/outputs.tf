output "volume_id" {
  description = "EBS data volume ID."
  value       = aws_ebs_volume.data.id
}

output "availability_zone" {
  description = "Availability zone of the data volume. EC2 instance must be in the same AZ."
  value       = aws_ebs_volume.data.availability_zone
}
