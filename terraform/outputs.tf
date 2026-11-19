# These outputs are what scripts/tf-sync.sh copies into .state/cluster.env so that the SSM-based
# cluster scripts (05 to 08, ssm.sh) work on top of Terraform-built infrastructure.

output "cluster" {
  description = "Cluster name (resource prefix and project tag)."
  value       = var.cluster
}

output "aws_region" {
  description = "Region of every resource."
  value       = var.aws_region
}

output "vpc_id" {
  description = "ID of the dedicated VPC."
  value       = aws_vpc.main.id
}

output "public_subnet_id" {
  description = "Public subnet (NAT gateway only)."
  value       = aws_subnet.public.id
}

output "private_subnet_id" {
  description = "Private subnet (all nodes)."
  value       = aws_subnet.private.id
}

output "nat_gateway_id" {
  description = "NAT gateway ID."
  value       = aws_nat_gateway.main.id
}

output "nat_public_ip" {
  description = "Public IP that all outbound node traffic appears from."
  value       = aws_eip.nat.public_ip
}

output "cp_security_group_id" {
  description = "Control plane security group."
  value       = aws_security_group.cp.id
}

output "worker_security_group_id" {
  description = "Worker security group."
  value       = aws_security_group.worker.id
}

output "cp_instance_id" {
  description = "Control plane instance ID."
  value       = aws_instance.cp.id
}

output "worker1_instance_id" {
  description = "Worker 1 instance ID."
  value       = aws_instance.worker["worker1"].id
}

output "worker2_instance_id" {
  description = "Worker 2 instance ID."
  value       = aws_instance.worker["worker2"].id
}

output "cp_private_ip" {
  description = "Private IP of the control plane (the Kubernetes API endpoint)."
  value       = aws_instance.cp.private_ip
}

output "ami_id" {
  description = "AMI the nodes were launched from."
  value       = local.ami_id
}

output "next_steps" {
  description = "What to do after terraform apply."
  value       = <<-EOT
    Infrastructure is ready. The nodes need 3-5 minutes to register with SSM and finish their
    first-boot setup. Then:

      make tf-sync     # copy these outputs into .state/cluster.env
      make status      # wait until all three instances show Online
      make cluster     # kubeadm init, Calico, join workers, smoke test (through SSM)

    Open a shell on the control plane (no SSH):
      aws ssm start-session --target ${aws_instance.cp.id} --region ${var.aws_region}
  EOT
}
