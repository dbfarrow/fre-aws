variable "project_name" {
  description = "Project name; matches the base module's project_name."
  type        = string
}

variable "aws_region" {
  description = "AWS region; matches the base module's aws_region."
  type        = string
}

variable "username" {
  description = "Username this data volume belongs to."
  type        = string
}

variable "subnet_id" {
  description = "Subnet ID where the user's EC2 instance lives. Used to derive the availability zone."
  type        = string
}

variable "ebs_data_volume_size_gb" {
  description = "Size of the data volume in GB."
  type        = number
  default     = 30
}
