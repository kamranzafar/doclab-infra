############################################
# AWS Network Firewall (the firewall icon on the boundary in the diagram)
#
# Traffic path:
#   Internet -> IGW -> (edge route table) -> firewall endpoint -> DMZ public subnet
#   DMZ public subnet (incl. NAT) -> firewall endpoint -> firewall subnet -> IGW
############################################
resource "aws_networkfirewall_rule_group" "perimeter" {
  count = local.enable_firewall ? 1 : 0

  name     = "${local.name}-perimeter"
  type     = "STATEFUL"
  capacity = 100

  rule_group {
    rule_variables {
      ip_sets {
        key = "HOME_NET"
        ip_set {
          definition = [var.vpc_cidr]
        }
      }
      ip_sets {
        key = "WEB_SERVER"
        ip_set {
          definition = ["${local.host_ips["webserver"]}/32"]
        }
      }
      ip_sets {
        key = "VPN_SERVER"
        ip_set {
          definition = ["${local.host_ips["openvpn"]}/32"]
        }
      }
    }

    rules_source {
      rules_string = <<-EOT
        pass tcp any any -> $WEB_SERVER [80,443] (msg:"Inbound HTTP(S) to DMZ NGINX"; flow:to_server; sid:1000001; rev:1;)
        pass udp any any -> $VPN_SERVER 1194 (msg:"Inbound OpenVPN"; sid:1000002; rev:1;)
        pass ip $HOME_NET any -> any any (msg:"Outbound from VPC"; sid:1000003; rev:1;)
        drop ip any any -> $HOME_NET any (msg:"Default deny new inbound"; flow:to_server; sid:1000004; rev:1;)
      EOT
    }

    stateful_rule_options {
      rule_order = "DEFAULT_ACTION_ORDER"
    }
  }
}

resource "aws_networkfirewall_firewall_policy" "this" {
  count = local.enable_firewall ? 1 : 0

  name = "${local.name}-policy"

  firewall_policy {
    stateless_default_actions          = ["aws:forward_to_sfe"]
    stateless_fragment_default_actions = ["aws:forward_to_sfe"]

    stateful_rule_group_reference {
      resource_arn = aws_networkfirewall_rule_group.perimeter[0].arn
    }
  }
}

resource "aws_networkfirewall_firewall" "this" {
  count = local.enable_firewall ? 1 : 0

  name                = "${local.name}-firewall"
  firewall_policy_arn = aws_networkfirewall_firewall_policy.this[0].arn
  vpc_id              = aws_vpc.this.id

  subnet_mapping {
    subnet_id = aws_subnet.this["firewall"].id
  }
}

locals {
  firewall_endpoint_id = local.enable_firewall ? one([
    for s in aws_networkfirewall_firewall.this[0].firewall_status[0].sync_states : s.attachment[0].endpoint_id
  ]) : null
}

# Ingress routing: return/inbound traffic for the DMZ is steered through the firewall
resource "aws_route_table" "igw_edge" {
  count = local.enable_firewall ? 1 : 0

  vpc_id = aws_vpc.this.id

  route {
    cidr_block      = local.subnets["dmz_public"].cidr
    vpc_endpoint_id = local.firewall_endpoint_id
  }

  tags = { Name = "${local.name}-rt-igw-edge" }
}

resource "aws_route_table_association" "igw_edge" {
  count = local.enable_firewall ? 1 : 0

  gateway_id     = aws_internet_gateway.this.id
  route_table_id = aws_route_table.igw_edge[0].id
}

############################################
# Firewall logging
############################################
resource "aws_cloudwatch_log_group" "firewall" {
  for_each = local.enable_firewall ? toset(["alert", "flow"]) : toset([])

  name              = "/${local.name}/network-firewall/${each.key}"
  retention_in_days = 90
}

resource "aws_networkfirewall_logging_configuration" "this" {
  count = local.enable_firewall ? 1 : 0

  firewall_arn = aws_networkfirewall_firewall.this[0].arn

  logging_configuration {
    log_destination_config {
      log_destination      = { logGroup = aws_cloudwatch_log_group.firewall["alert"].name }
      log_destination_type = "CloudWatchLogs"
      log_type             = "ALERT"
    }
    log_destination_config {
      log_destination      = { logGroup = aws_cloudwatch_log_group.firewall["flow"].name }
      log_destination_type = "CloudWatchLogs"
      log_type             = "FLOW"
    }
  }
}
