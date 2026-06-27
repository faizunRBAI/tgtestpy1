terraform {
  required_version = ">= 1.5.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }

  backend "s3" {}
}

provider "aws" {
  region = var.aws_region
}

# WAF and Shield for CloudFront must be in us-east-1
provider "aws" {
  alias  = "us_east_1"
  region = "us-east-1"
}

# ---------------------------------------------------------------------------
# Variables
# ---------------------------------------------------------------------------
variable "aws_region" {
  type    = string
  default = "us-east-1"
}

variable "project_name" {
  type = string
}

variable "public_key" {
  type      = string
  sensitive = true
}

variable "operator_cidr" {
  type        = string
  default     = "0.0.0.0/0"
  description = "CIDR allowed SSH access for Ansible"
}

variable "instance_type" {
  type    = string
  default = "t3.small"
}

variable "tf_state_bucket" {
  type = string
}

# ---------------------------------------------------------------------------
# Data sources
# ---------------------------------------------------------------------------
data "aws_ami" "amazon_linux_2023" {
  most_recent = true
  owners      = ["amazon"]

  filter {
    name   = "name"
    values = ["al2023-ami-*-x86_64"]
  }

  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }
}

data "aws_ec2_managed_prefix_list" "cloudfront" {
  name = "com.amazonaws.global.cloudfront.origin-facing"
}

# ---------------------------------------------------------------------------
# Networking - default VPC / subnets
# ---------------------------------------------------------------------------
data "aws_vpc" "default" {
  default = true
}

# Only AZs that are fully available (excludes us-east-1e and other AZs with
# limited or no support for modern instance types like t3.small)
data "aws_availability_zones" "available" {
  state = "available"
  filter {
    name   = "opt-in-status"
    values = ["opt-in-not-required"]
  }
}

data "aws_subnets" "default" {
  filter {
    name   = "vpc-id"
    values = [data.aws_vpc.default.id]
  }
  # Only consider default subnets in fully-available AZs
  filter {
    name   = "availabilityZone"
    values = data.aws_availability_zones.available.names
  }
  filter {
    name   = "default-for-az"
    values = ["true"]
  }
}

# ---------------------------------------------------------------------------
# SSH Key Pair
# ---------------------------------------------------------------------------
resource "aws_key_pair" "app" {
  key_name   = "${var.project_name}-key"
  public_key = var.public_key
}

# ---------------------------------------------------------------------------
# IAM Role for EC2 (CloudWatch, X-Ray, SSM)
# ---------------------------------------------------------------------------
resource "aws_iam_role" "ec2" {
  name = "${var.project_name}-ec2-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "ec2.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy_attachment" "cloudwatch" {
  role       = aws_iam_role.ec2.name
  policy_arn = "arn:aws:iam::aws:policy/CloudWatchAgentServerPolicy"
}

resource "aws_iam_role_policy_attachment" "xray" {
  role       = aws_iam_role.ec2.name
  policy_arn = "arn:aws:iam::aws:policy/AWSXRayDaemonWriteAccess"
}

resource "aws_iam_role_policy_attachment" "ssm" {
  role       = aws_iam_role.ec2.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_iam_instance_profile" "ec2" {
  name = "${var.project_name}-ec2-profile"
  role = aws_iam_role.ec2.name
}

# ---------------------------------------------------------------------------
# Security Groups
# ---------------------------------------------------------------------------
resource "aws_security_group" "ec2" {
  name        = "${var.project_name}-ec2-sg"
  description = "EC2 app security group"
  vpc_id      = data.aws_vpc.default.id

  # HTTP from CloudFront prefix list only
  ingress {
    description     = "HTTP from CloudFront"
    from_port       = 80
    to_port         = 80
    protocol        = "tcp"
    prefix_list_ids = [data.aws_ec2_managed_prefix_list.cloudfront.id]
  }

  # SSH from operator CIDR for Ansible
  ingress {
    description = "SSH from operator"
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = [var.operator_cidr]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = { Name = "${var.project_name}-ec2-sg" }
}

# ---------------------------------------------------------------------------
# EC2 Instance
# ---------------------------------------------------------------------------
resource "aws_instance" "app" {
  ami                    = data.aws_ami.amazon_linux_2023.id
  instance_type          = var.instance_type
  key_name               = aws_key_pair.app.key_name
  iam_instance_profile   = aws_iam_instance_profile.ec2.name
  vpc_security_group_ids = [aws_security_group.ec2.id]
  # sort() gives a stable, deterministic first element from the filtered list
  # of default subnets, all of which are in fully-available AZs (never -1e)
  subnet_id              = sort(data.aws_subnets.default.ids)[0]

  root_block_device {
    volume_size           = 20
    volume_type           = "gp3"
    delete_on_termination = true
  }

  tags = { Name = "${var.project_name}-app" }
}

# Static / Elastic IP so the address survives stop/start
resource "aws_eip" "app" {
  instance = aws_instance.app.id
  domain   = "vpc"

  tags = { Name = "${var.project_name}-eip" }
}

# ---------------------------------------------------------------------------
# WAF WebACL (scope=CLOUDFRONT - must be in us-east-1)
# ---------------------------------------------------------------------------
resource "aws_wafv2_web_acl" "app" {
  provider    = aws.us_east_1
  name        = "${var.project_name}-waf"
  description = "WAF for ${var.project_name} CloudFront"
  scope       = "CLOUDFRONT"

  default_action {
    allow {}
  }

  rule {
    name     = "AWSManagedRulesCommonRuleSet"
    priority = 1

    override_action {
      none {}
    }

    statement {
      managed_rule_group_statement {
        name        = "AWSManagedRulesCommonRuleSet"
        vendor_name = "AWS"
      }
    }

    visibility_config {
      cloudwatch_metrics_enabled = true
      metric_name                = "${var.project_name}-common-rules"
      sampled_requests_enabled   = true
    }
  }

  rule {
    name     = "AWSManagedRulesKnownBadInputsRuleSet"
    priority = 2

    override_action {
      none {}
    }

    statement {
      managed_rule_group_statement {
        name        = "AWSManagedRulesKnownBadInputsRuleSet"
        vendor_name = "AWS"
      }
    }

    visibility_config {
      cloudwatch_metrics_enabled = true
      metric_name                = "${var.project_name}-bad-inputs"
      sampled_requests_enabled   = true
    }
  }

  visibility_config {
    cloudwatch_metrics_enabled = true
    metric_name                = "${var.project_name}-waf"
    sampled_requests_enabled   = true
  }

  tags = { Name = "${var.project_name}-waf" }
}

# ---------------------------------------------------------------------------
# CloudFront Distribution
# ---------------------------------------------------------------------------
resource "aws_cloudfront_distribution" "app" {
  provider = aws.us_east_1
  enabled  = true
  comment  = "${var.project_name} distribution"

  web_acl_id = aws_wafv2_web_acl.app.arn

  origin {
    domain_name = aws_eip.app.public_dns
    origin_id   = "${var.project_name}-ec2-origin"

    custom_origin_config {
      http_port              = 80
      https_port             = 443
      origin_protocol_policy = "http-only"
      origin_ssl_protocols   = ["TLSv1.2"]
    }

    custom_header {
      name  = "X-Origin-Verify"
      value = var.project_name
    }
  }

  default_cache_behavior {
    allowed_methods        = ["DELETE", "GET", "HEAD", "OPTIONS", "PATCH", "POST", "PUT"]
    cached_methods         = ["GET", "HEAD"]
    target_origin_id       = "${var.project_name}-ec2-origin"
    viewer_protocol_policy = "redirect-to-https"
    compress               = true

    forwarded_values {
      query_string = true
      headers      = ["Host", "X-Forwarded-For"]
      cookies {
        forward = "none"
      }
    }

    min_ttl     = 0
    default_ttl = 0
    max_ttl     = 0
  }

  # Health check path
  custom_error_response {
    error_code         = 502
    response_code      = 502
    response_page_path = "/health"
  }

  restrictions {
    geo_restriction {
      restriction_type = "none"
    }
  }

  viewer_certificate {
    cloudfront_default_certificate = true
  }

  tags = { Name = "${var.project_name}-cf" }
}

# ---------------------------------------------------------------------------
# AWS Shield Advanced - protect the CloudFront distribution
# ---------------------------------------------------------------------------
resource "aws_shield_protection" "cloudfront" {
  name         = "${var.project_name}-shield-cf"
  resource_arn = aws_cloudfront_distribution.app.arn
}

# ---------------------------------------------------------------------------
# CloudTrail - log to existing TF_STATE_BUCKET under cloudtrail/ prefix
# ---------------------------------------------------------------------------
data "aws_caller_identity" "current" {}

resource "aws_cloudtrail" "app" {
  name                          = "${var.project_name}-trail"
  s3_bucket_name                = var.tf_state_bucket
  s3_key_prefix                 = "cloudtrail"
  include_global_service_events = true
  is_multi_region_trail         = true
  enable_log_file_validation    = true

  # Ensure the bucket policy is applied before CloudTrail validates it;
  # without this, both resources are created in parallel and CloudTrail
  # sees an InsufficientS3BucketPolicyException.
  depends_on = [aws_s3_bucket_policy.cloudtrail]

  tags = { Name = "${var.project_name}-trail" }
}

# S3 bucket policy allowing CloudTrail to write to the existing bucket
resource "aws_s3_bucket_policy" "cloudtrail" {
  bucket = var.tf_state_bucket

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "AWSCloudTrailAclCheck"
        Effect = "Allow"
        Principal = {
          Service = "cloudtrail.amazonaws.com"
        }
        Action   = "s3:GetBucketAcl"
        Resource = "arn:aws:s3:::${var.tf_state_bucket}"
      },
      {
        Sid    = "AWSCloudTrailWrite"
        Effect = "Allow"
        Principal = {
          Service = "cloudtrail.amazonaws.com"
        }
        Action   = "s3:PutObject"
        Resource = "arn:aws:s3:::${var.tf_state_bucket}/cloudtrail/AWSLogs/${data.aws_caller_identity.current.account_id}/*"
        Condition = {
          StringEquals = {
            "s3:x-amz-acl" = "bucket-owner-full-control"
          }
        }
      }
    ]
  })
}

# ---------------------------------------------------------------------------
# CloudWatch Log Group for application logs
# ---------------------------------------------------------------------------
resource "aws_cloudwatch_log_group" "app" {
  name              = "/aws/ec2/${var.project_name}/gunicorn"
  retention_in_days = 30
  tags              = { Name = "${var.project_name}-logs" }
}

resource "aws_cloudwatch_log_group" "system" {
  name              = "/aws/ec2/${var.project_name}/system"
  retention_in_days = 30
  tags              = { Name = "${var.project_name}-system-logs" }
}

# ---------------------------------------------------------------------------
# Outputs
# ---------------------------------------------------------------------------
output "instance_id" {
  value = aws_instance.app.id
}

output "instance_public_ip" {
  value = aws_eip.app.public_ip
}

output "instance_public_dns" {
  value = aws_eip.app.public_dns
}

output "cloudfront_domain" {
  value = aws_cloudfront_distribution.app.domain_name
}

output "cloudfront_arn" {
  value = aws_cloudfront_distribution.app.arn
}

output "app_url" {
  value = "https://${aws_cloudfront_distribution.app.domain_name}"
}
