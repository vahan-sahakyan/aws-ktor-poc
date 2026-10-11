# single t3.micro running k3s (ktor + postgres + envoy gateway) with no load balancer.
# every resource here is free-tier eligible or free outright; see README "Cost model".

terraform {
  required_version = ">= 1.9"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.68"
    }
    tls = {
      source  = "hashicorp/tls"
      version = "~> 4.4"
    }
    local = {
      source  = "hashicorp/local"
      version = "~> 2.9"
    }
  }
}

# ---------------------------------------------------------------------------
# variables
# ---------------------------------------------------------------------------

variable "region" {
  description = "AWS region"
  type        = string
  default     = "us-east-1"
}

variable "project" {
  description = "Name prefix and tag for every resource"
  type        = string
  default     = "ktor-poc"
}

variable "instance_type" {
  description = "Free-plan eligible burstable type; t3.small (2 GB) is the escape hatch if 1 GB thrashes"
  type        = string
  default     = "t3.micro"

  validation {
    condition     = contains(["t3.micro", "t3.small"], var.instance_type)
    error_message = "Only t3.micro or t3.small are allowed to stay on the free plan."
  }
}

variable "ssh_cidr" {
  description = "CIDR allowed to reach port 22; narrow to your own /32 when possible"
  type        = string
  default     = "0.0.0.0/0"
}

variable "swap_size_gb" {
  description = "Size of the swapfile created on the root volume"
  type        = number
  default     = 4
}

variable "budget_email" {
  description = "Email that receives the zero-spend budget alerts"
  type        = string
}

# ---------------------------------------------------------------------------
# provider
# ---------------------------------------------------------------------------

provider "aws" {
  region = var.region

  default_tags {
    tags = {
      Project   = var.project
      ManagedBy = "terraform"
    }
  }
}

data "aws_availability_zones" "available" {
  state = "available"
}

# latest Amazon Linux 2023 x86_64 (cgroup v2, required for kubelet LimitedSwap)
data "aws_ssm_parameter" "al2023" {
  name = "/aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-x86_64"
}

# ---------------------------------------------------------------------------
# network: vpc, one public subnet, igw. no nat gateway (it is billed hourly)
# ---------------------------------------------------------------------------

resource "aws_vpc" "main" {
  cidr_block           = "10.0.0.0/16"
  enable_dns_support   = true
  enable_dns_hostnames = true

  tags = { Name = "${var.project}-vpc" }
}

resource "aws_internet_gateway" "main" {
  vpc_id = aws_vpc.main.id

  tags = { Name = "${var.project}-igw" }
}

resource "aws_subnet" "public" {
  vpc_id                  = aws_vpc.main.id
  cidr_block              = "10.0.1.0/24"
  availability_zone       = data.aws_availability_zones.available.names[0]
  map_public_ip_on_launch = true

  tags = { Name = "${var.project}-public" }
}

resource "aws_route_table" "public" {
  vpc_id = aws_vpc.main.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.main.id
  }

  tags = { Name = "${var.project}-public" }
}

resource "aws_route_table_association" "public" {
  subnet_id      = aws_subnet.public.id
  route_table_id = aws_route_table.public.id
}

# ---------------------------------------------------------------------------
# security group: 22, 80, 443 in; everything out
# ---------------------------------------------------------------------------

resource "aws_security_group" "node" {
  name        = "${var.project}-node"
  description = "SSH, HTTP and HTTPS to the single k3s node"
  vpc_id      = aws_vpc.main.id

  tags = { Name = "${var.project}-node" }
}

resource "aws_vpc_security_group_ingress_rule" "ssh" {
  security_group_id = aws_security_group.node.id
  description       = "SSH"
  cidr_ipv4         = var.ssh_cidr
  ip_protocol       = "tcp"
  from_port         = 22
  to_port           = 22
}

resource "aws_vpc_security_group_ingress_rule" "http" {
  security_group_id = aws_security_group.node.id
  description       = "HTTP and WebSocket (ws://)"
  cidr_ipv4         = "0.0.0.0/0"
  ip_protocol       = "tcp"
  from_port         = 80
  to_port           = 80
}

resource "aws_vpc_security_group_ingress_rule" "https" {
  security_group_id = aws_security_group.node.id
  description       = "HTTPS and WebSocket (wss://)"
  cidr_ipv4         = "0.0.0.0/0"
  ip_protocol       = "tcp"
  from_port         = 443
  to_port           = 443
}

resource "aws_vpc_security_group_egress_rule" "all" {
  security_group_id = aws_security_group.node.id
  description       = "All outbound"
  cidr_ipv4         = "0.0.0.0/0"
  ip_protocol       = "-1"
}

# ---------------------------------------------------------------------------
# ssh key: generated locally, written as a 0600 .pem next to this file
# ---------------------------------------------------------------------------

resource "tls_private_key" "ssh" {
  algorithm = "ED25519"
}

resource "aws_key_pair" "ssh" {
  key_name   = "${var.project}-key"
  public_key = tls_private_key.ssh.public_key_openssh
}

resource "local_sensitive_file" "ssh_pem" {
  filename        = "${path.module}/${var.project}.pem"
  content         = tls_private_key.ssh.private_key_openssh
  file_permission = "0600"
}

# ---------------------------------------------------------------------------
# the single node
# ---------------------------------------------------------------------------

resource "aws_instance" "node" {
  ami                    = data.aws_ssm_parameter.al2023.insecure_value
  instance_type          = var.instance_type
  subnet_id              = aws_subnet.public.id
  vpc_security_group_ids = [aws_security_group.node.id]
  key_name               = aws_key_pair.ssh.key_name

  # one auto-assigned public ipv4 (no elastic ip, which is billed even while stopped)
  associate_public_ip_address = true

  # t3 defaults to "unlimited", which bills cpu above the baseline; standard throttles instead
  credit_specification {
    cpu_credits = "standard"
  }

  metadata_options {
    http_tokens                 = "required"
    http_put_response_hop_limit = 2
  }

  root_block_device {
    volume_size           = 30
    volume_type           = "gp3"
    encrypted             = true
    delete_on_termination = true
  }

  user_data = templatefile("${path.module}/user_data.sh", {
    swap_size_gb = var.swap_size_gb
  })
  user_data_replace_on_change = true

  # a newer ami must not silently replace the node (and wipe postgres data)
  lifecycle {
    ignore_changes = [ami]
  }

  tags = { Name = "${var.project}-node" }
}

# ---------------------------------------------------------------------------
# zero-spend guardrail (budgets are free)
# ---------------------------------------------------------------------------

resource "aws_budgets_budget" "zero_spend" {
  name         = "${var.project}-zero-spend"
  budget_type  = "COST"
  limit_amount = "1.0"
  limit_unit   = "USD"
  time_unit    = "MONTHLY"

  # alert on the first real cent, i.e. anything the free plan credits did not absorb
  notification {
    comparison_operator        = "GREATER_THAN"
    notification_type          = "ACTUAL"
    threshold                  = 0.01
    threshold_type             = "ABSOLUTE_VALUE"
    subscriber_email_addresses = [var.budget_email]
  }

  notification {
    comparison_operator        = "GREATER_THAN"
    notification_type          = "FORECASTED"
    threshold                  = 100
    threshold_type             = "PERCENTAGE"
    subscriber_email_addresses = [var.budget_email]
  }
}

# ---------------------------------------------------------------------------
# outputs
# ---------------------------------------------------------------------------

output "instance_id" {
  value = aws_instance.node.id
}

output "public_ip" {
  value = aws_instance.node.public_ip
}

output "ssh_command" {
  value = "ssh -i ${local_sensitive_file.ssh_pem.filename} ec2-user@${aws_instance.node.public_ip}"
}

output "app_url" {
  value = "http://${aws_instance.node.public_ip}"
}
