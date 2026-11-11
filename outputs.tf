output "vpc_id" {
  value = aws_vpc.this.id
}

output "webserver_public_ip" {
  value = aws_eip.public["webserver"].public_ip
}

output "openvpn_public_ip" {
  value = aws_eip.public["openvpn"].public_ip
}

output "hosts" {
  description = "FQDN -> private IP for every EC2 host"
  value       = { for k in keys(local.hosts) : local.host_fqdns[k] => local.host_ips[k] }
}

output "instance_ids" {
  description = "Use with: aws ssm start-session --target <id>"
  value       = { for k, i in aws_instance.this : local.host_fqdns[k] => i.id }
}

output "ad_dns_ips" {
  value = local.enable_ad ? aws_directory_service_directory.corp[0].dns_ip_addresses : null
}

output "ad_admin_secret_arn" {
  value = local.enable_ad ? aws_secretsmanager_secret.ad_admin[0].arn : null
}

output "pii_db_endpoint" {
  value = aws_db_instance.pii.address
}

output "pii_db_master_secret_arn" {
  value = aws_db_instance.pii.master_user_secret[0].secret_arn
}

output "storage_bucket" {
  value = aws_s3_bucket.this["storage"].bucket
}

output "backup_bucket" {
  value = aws_s3_bucket.this["backup"].bucket
}

output "workspaces_registration_code" {
  value = local.enable_workspaces ? aws_workspaces_directory.corp[0].registration_code : null
}

output "workspace_ids" {
  value = { for u, w in aws_workspaces_workspace.user : u => w.id }
}

output "firewall_endpoint_id" {
  value = local.firewall_endpoint_id
}

output "lite_mode" {
  description = "true when deployed in lite mode (no AD, WorkSpaces, Network Firewall; AlmaLinux hosts)"
  value       = var.lite_mode
}
