############################################
# OS images
#   full: RHEL 9 (Red Hat official, pay-as-you-go licence)
#   lite: AlmaLinux 9 (official community AMI, no licence charge, not a Marketplace image)
############################################
data "aws_ami" "rhel9" {
  count = var.lite_mode ? 0 : 1

  most_recent = true
  owners      = ["309956199498"] # Red Hat

  filter {
    name   = "name"
    values = ["RHEL-9.*_HVM-*-x86_64-*-Hourly2-GP3"]
  }

  filter {
    name   = "architecture"
    values = ["x86_64"]
  }
}

data "aws_ami" "alma9" {
  count = var.lite_mode ? 1 : 0

  most_recent = true
  owners      = ["764336703387"] # AlmaLinux OS Foundation

  filter {
    name   = "name"
    values = ["AlmaLinux OS 9.*"]
  }

  filter {
    name   = "architecture"
    values = ["x86_64"]
  }
}

############################################
# Hosts: rhel-server, jumpserver, rhel-security, security-main, webserver, openvpn
############################################
resource "aws_instance" "this" {
  for_each = local.hosts

  ami                    = var.lite_mode ? data.aws_ami.alma9[0].id : data.aws_ami.rhel9[0].id
  instance_type          = local.instance_types[each.key]
  subnet_id              = aws_subnet.this[each.value.subnet].id
  private_ip             = local.host_ips[each.key]
  vpc_security_group_ids = [aws_security_group.this[each.key].id]
  iam_instance_profile   = aws_iam_instance_profile.host[each.key].name
  key_name               = var.key_name

  # OpenVPN routes client traffic, so it must not drop packets not addressed to itself
  source_dest_check = each.key != "openvpn"

  user_data = templatefile("${path.module}/templates/bootstrap.sh.tftpl", {
    role               = each.key
    fqdn               = local.host_fqdns[each.key]
    region             = var.region
    forward_logs       = each.key != "security_main"
    graylog_ip         = local.host_ips["security_main"]
    ansible_public_key = trimspace(tls_private_key.ansible.public_key_openssh)
    ansible_key_param  = aws_ssm_parameter.ansible_key.name
    inventory          = local.ansible_inventory
  })

  metadata_options {
    http_endpoint = "enabled"
    http_tokens   = "required" # IMDSv2 only
  }

  root_block_device {
    volume_type = "gp3"
    volume_size = each.value.volume_gb
    encrypted   = true
  }

  tags = {
    Name   = each.value.hostname
    Domain = each.value.domain
  }

  lifecycle {
    # Bootstrap runs once; don't rebuild hosts when a newer AMI appears or the script changes
    ignore_changes = [ami, user_data]
  }

  # Bootstrap needs outbound internet (RHUI, EPEL, SSM agent)
  depends_on = [
    aws_route.public_default,
    aws_route_table_association.this,
    aws_nat_gateway.this,
  ]
}

############################################
# Elastic IPs for the public DMZ hosts
############################################
resource "aws_eip" "public" {
  for_each = local.public_hosts

  domain     = "vpc"
  tags       = { Name = "${local.name}-${each.key}" }
  depends_on = [aws_internet_gateway.this]
}

resource "aws_eip_association" "public" {
  for_each = local.public_hosts

  allocation_id = aws_eip.public[each.key].id
  instance_id   = aws_instance.this[each.key].id
}

############################################
# VPC Traffic Mirroring: webserver -> security-main (Snort)
############################################
resource "aws_ec2_traffic_mirror_target" "snort" {
  count = local.enable_mirroring ? 1 : 0

  description          = "Snort on security-main"
  network_interface_id = aws_instance.this["security_main"].primary_network_interface_id
}

resource "aws_ec2_traffic_mirror_filter" "all" {
  count = local.enable_mirroring ? 1 : 0

  description = "Mirror all traffic"
}

resource "aws_ec2_traffic_mirror_filter_rule" "all" {
  for_each = local.enable_mirroring ? toset(["ingress", "egress"]) : toset([])

  traffic_mirror_filter_id = aws_ec2_traffic_mirror_filter.all[0].id
  traffic_direction        = each.key
  rule_number              = 100
  rule_action              = "accept"
  source_cidr_block        = "0.0.0.0/0"
  destination_cidr_block   = "0.0.0.0/0"
}

resource "aws_ec2_traffic_mirror_session" "webserver" {
  count = local.enable_mirroring ? 1 : 0

  description              = "webserver -> Snort"
  network_interface_id     = aws_instance.this["webserver"].primary_network_interface_id
  traffic_mirror_filter_id = aws_ec2_traffic_mirror_filter.all[0].id
  traffic_mirror_target_id = aws_ec2_traffic_mirror_target.snort[0].id
  session_number           = 1
}

############################################
# Ansible inventory, also written locally for convenience
############################################
resource "local_file" "ansible_inventory" {
  filename        = "${path.module}/ansible/inventory.ini"
  content         = local.ansible_inventory
  file_permission = "0644"
}
