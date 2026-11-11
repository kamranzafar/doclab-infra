############################################
# Ansible controller key
# rhel-server pulls the private key from SSM at boot; every host trusts the public key.
# NOTE: the private key is also stored in Terraform state - protect your state backend.
############################################
resource "tls_private_key" "ansible" {
  algorithm = "ED25519"
}

resource "aws_ssm_parameter" "ansible_key" {
  name        = "/${local.name}/ansible/ssh-private-key"
  description = "SSH private key used by Ansible on rhel-server"
  type        = "SecureString"
  value       = tls_private_key.ansible.private_key_openssh
}

############################################
# Per-host instance roles (SSM Session Manager for all, extras per host)
############################################
data "aws_iam_policy_document" "ec2_assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["ec2.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "host" {
  for_each = local.hosts

  name               = "${local.name}-${each.value.hostname}"
  assume_role_policy = data.aws_iam_policy_document.ec2_assume.json
}

resource "aws_iam_role_policy_attachment" "ssm" {
  for_each = local.hosts

  role       = aws_iam_role.host[each.key].name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_iam_instance_profile" "host" {
  for_each = local.hosts

  name = "${local.name}-${each.value.hostname}"
  role = aws_iam_role.host[each.key].name
}

data "aws_iam_policy_document" "ansible_key_read" {
  statement {
    actions   = ["ssm:GetParameter"]
    resources = [aws_ssm_parameter.ansible_key.arn]
  }
}

# Webserver (and DB dumps taken from it) -> Backup Storage (S3)
data "aws_iam_policy_document" "backup_rw" {
  statement {
    actions   = ["s3:ListBucket"]
    resources = [aws_s3_bucket.this["backup"].arn]
  }
  statement {
    actions   = ["s3:GetObject", "s3:PutObject"]
    resources = ["${aws_s3_bucket.this["backup"].arn}/*"]
  }
}

locals {
  host_extra_policies = {
    rhel_server = data.aws_iam_policy_document.ansible_key_read.json
    webserver   = data.aws_iam_policy_document.backup_rw.json
  }
}

resource "aws_iam_role_policy" "extra" {
  for_each = local.host_extra_policies

  name   = "${local.name}-${each.key}-extra"
  role   = aws_iam_role.host[each.key].id
  policy = each.value
}
