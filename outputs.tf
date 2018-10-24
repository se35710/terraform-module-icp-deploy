
output "install_complete" {
  depends_on  = ["null_resource.icp-install"]
  description = "Boolean value that is set to true when ICP installation process is completed"
  value       = "true"
}

output "icp_version" {
  value = "${var.icp-version}"
}

output "cluster_ips" {
  value = "${local.icp-ips}"
}
