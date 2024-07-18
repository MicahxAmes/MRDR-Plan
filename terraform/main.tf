provider "aws" {
  region = "us-east-1" # Primary region
}

provider "aws" {
  alias  = "secondary" # Secondary region
  region = "us-west-2"
}

# Primary region VPC, subnet, and EC2 instance
resource "aws_vpc" "primary_vpc" {
  cidr_block = "10.0.0.0/16"
}

resource "aws_subnet" "primary_subnet" {
  vpc_id            = aws_vpc.primary_vpc.id
  cidr_block        = "10.0.1.0/24"
  availability_zone = "us-east-1a"
}

resource "aws_instance" "primary_instance" {
  ami           = "ami-0d1cc141027ca9eb4" # Ubuntu 20.04
  instance_type = "t2.micro"
  subnet_id     = aws_subnet.primary_subnet.id
}

# Secondary region VPC, subnet, and EC2 instance
resource "aws_vpc" "secondary_vpc" {
  provider   = aws.secondary
  cidr_block = "10.1.0.0/16"
}

resource "aws_subnet" "secondary_subnet" {
  provider          = aws.secondary
  vpc_id            = aws_vpc.secondary_vpc.id
  cidr_block        = "10.1.1.0/24"
  availability_zone = "us-west-2a"
}

resource "aws_instance" "secondary_instance" {
  provider      = aws.secondary
  ami           = "ami-04bad3c587fe60d89" # Ubuntu 20.04 based in US West 2
  instance_type = "t2.micro"
  subnet_id     = aws_subnet.secondary_subnet.id
}

# IAM role for replication
resource "aws_iam_role" "replication_role" {
  name = "replication-role"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action    = "sts:AssumeRole"
      Effect    = "Allow"
      Principal = {
        Service = "s3.amazonaws.com"
      }
    }]
  })
}

# IAM policy for replication
resource "aws_iam_policy" "replication_policy" {
  name   = "s3-replication-policy"
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action = [
          "s3:GetReplicationConfiguration",
          "s3:ListBucket"
        ]
        Effect = "Allow"
        Resource = [
          aws_s3_bucket.primary_bucket.arn
        ]
      },
      {
        Action = [
          "s3:GetObjectVersion",
          "s3:GetObjectVersionAcl"
        ]
        Effect = "Allow"
        Resource = [
          "${aws_s3_bucket.primary_bucket.arn}/*"
        ]
      },
      {
        Action = [
          "s3:ReplicateObject",
          "s3:ReplicateDelete",
          "s3:ReplicateTags",
          "s3:GetObjectVersionTagging"
        ]
        Effect = "Allow"
        Resource = "${aws_s3_bucket.secondary_bucket.arn}/*"
      }
    ]
  })
}

resource "aws_iam_role_policy_attachment" "replication_policy_attachment" {
  role       = aws_iam_role.replication_role.name
  policy_arn = aws_iam_policy.replication_policy.arn
}

# S3 bucket in primary region with versioning and replication configuration
resource "aws_s3_bucket" "primary_bucket" {
  bucket = "primary-bucket"
}

resource "aws_s3_bucket_versioning" "primary_bucket_versioning" {
  bucket = aws_s3_bucket.primary_bucket.id

  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_replication_configuration" "primary_bucket_replication" {
  bucket = aws_s3_bucket.primary_bucket.id

  role = aws_iam_role.replication_role.arn

  rule {
    id     = "replication-rule"
    status = "Enabled"
    prefix = ""

    destination {
      bucket        = aws_s3_bucket.secondary_bucket.arn
    }
  }
}

# S3 bucket in secondary region with versioning
resource "aws_s3_bucket" "secondary_bucket" {
  provider = aws.secondary
  bucket   = "secondary-bucket"
}

resource "aws_s3_bucket_versioning" "secondary_bucket_versioning" {
  bucket = aws_s3_bucket.secondary_bucket.id
  versioning_configuration {
    status = "Enabled"
  }
}

# Elastic IP for primary instance
resource "aws_eip" "primary" {
  instance = aws_instance.primary_instance.id
}

# Route53 health check and failover routing policies
resource "aws_route53_health_check" "primary_health_check" {
  fqdn              = aws_s3_bucket.primary_bucket.bucket_regional_domain_name
  port              = 443
  request_interval  = 30
  failure_threshold = 3
  resource_path     = "/"
  type              = "HTTP"

  tags = {
    Name = "primary_health_check"
  }
}

resource "aws_route53_health_check" "secondary_health_check" {
  fqdn              = aws_s3_bucket.secondary_bucket.bucket_regional_domain_name
  port              = 443
  request_interval  = 30
  failure_threshold = 3
  resource_path     = "/"
  type              = "HTTP"

  tags = {
    Name = "secondary_health_check"
  }
}

resource "aws_route53_record" "failover_record" {
  zone_id = var.route53_zone_id
  name    = "api.example.com"
  type    = "A"
  set_identifier = "primary"

  failover_routing_policy {
    type = "PRIMARY"
  }

  health_check_id = aws_route53_health_check.primary_health_check.id
  records         = [aws_eip.primary.public_ip]
  ttl             = 60
}

resource "aws_route53_record" "secondary_record" {
  zone_id = var.route53_zone_id 
  name    = "api.example.com"
  type    = "A"
  set_identifier = "secondary"

  failover_routing_policy {
    type = "SECONDARY"
  }

  records = [aws_instance.secondary_instance.public_ip] 
  ttl     = 60

  health_check_id = aws_route53_health_check.secondary_health_check.id 
}

