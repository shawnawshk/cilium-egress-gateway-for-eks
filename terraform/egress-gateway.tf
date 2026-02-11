# Elastic IP for egress gateway
# This will be manually associated with the gateway node after it's created
resource "aws_eip" "egress_gateway" {
  domain = "vpc"

  tags = {
    Name = "${var.cluster_name}-egress-gateway-eip"
  }
}

# Output the egress IP for reference
output "egress_gateway_public_ip" {
  description = "Public IP address for egress gateway (static egress IP)"
  value       = aws_eip.egress_gateway.public_ip
}

output "egress_gateway_allocation_id" {
  description = "EIP allocation ID for manual association"
  value       = aws_eip.egress_gateway.id
}
