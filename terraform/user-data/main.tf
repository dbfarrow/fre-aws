data "aws_subnet" "user" {
  id = var.subnet_id
}

resource "aws_ebs_volume" "data" {
  availability_zone = data.aws_subnet.user.availability_zone
  size              = var.ebs_data_volume_size_gb
  type              = "gp3"
  encrypted         = true

  tags = {
    Name        = "${var.project_name}-${var.username}-data"
    Username    = var.username
    ProjectName = var.project_name
    DataVolume  = "true"
  }

  lifecycle {
    prevent_destroy = true
  }
}
