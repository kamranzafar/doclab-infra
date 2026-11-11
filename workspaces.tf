############################################
# workspaces.doc - AWS WorkSpaces joined to corp.doc
############################################
data "aws_iam_policy_document" "workspaces_assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["workspaces.amazonaws.com"]
    }
  }
}

# WorkSpaces requires this exact, account-wide role name
resource "aws_iam_role" "workspaces_default" {
  count = local.enable_workspaces && var.create_workspaces_default_role ? 1 : 0

  name               = "workspaces_DefaultRole"
  assume_role_policy = data.aws_iam_policy_document.workspaces_assume.json
}

resource "aws_iam_role_policy_attachment" "workspaces_default" {
  for_each = local.enable_workspaces && var.create_workspaces_default_role ? toset([
    "arn:aws:iam::aws:policy/AmazonWorkSpacesServiceAccess",
    "arn:aws:iam::aws:policy/AmazonWorkSpacesSelfServiceAccess",
  ]) : toset([])

  role       = aws_iam_role.workspaces_default[0].name
  policy_arn = each.key
}

resource "aws_workspaces_directory" "corp" {
  count = local.enable_workspaces ? 1 : 0

  directory_id = aws_directory_service_directory.corp[0].id
  subnet_ids   = [aws_subnet.this["workspaces_a"].id, aws_subnet.this["workspaces_b"].id]

  self_service_permissions {
    change_compute_type  = false
    increase_volume_size = false
    rebuild_workspace    = true
    restart_workspace    = true
    switch_running_mode  = false
  }

  workspace_access_properties {
    device_type_windows    = "ALLOW"
    device_type_osx        = "ALLOW"
    device_type_linux      = "ALLOW"
    device_type_web        = "DENY"
    device_type_ios        = "DENY"
    device_type_android    = "DENY"
    device_type_chromeos   = "DENY"
    device_type_zeroclient = "DENY"
  }

  workspace_creation_properties {
    custom_security_group_id            = aws_security_group.this["workspaces"].id
    enable_internet_access              = false # egress via NAT instead of public IPs
    user_enabled_as_local_administrator = false
  }

  depends_on = [aws_iam_role_policy_attachment.workspaces_default]
}

resource "aws_workspaces_workspace" "user" {
  for_each = local.enable_workspaces && var.workspace_bundle_id != null ? toset(var.workspace_users) : toset([])

  directory_id = aws_workspaces_directory.corp[0].id
  bundle_id    = var.workspace_bundle_id
  user_name    = each.key

  root_volume_encryption_enabled = true
  user_volume_encryption_enabled = true
  volume_encryption_key          = "alias/aws/workspaces"

  workspace_properties {
    running_mode                              = "AUTO_STOP"
    running_mode_auto_stop_timeout_in_minutes = 60
  }

  tags = { Name = "workstation-${lower(each.key)}", Domain = "workspaces.doc" }
}
