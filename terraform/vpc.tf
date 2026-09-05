# ---------------------------------------------------------------------------
# VPC
#
# Layout (2 AZs: ap-southeast-3b, ap-southeast-3c):
#
#   Internet
#      |
#   [IGW]
#      |
#   public-b  10.42.0.0/24   <- ALB, NAT Gateway
#   public-c  10.42.1.0/24   <- ALB
#      |
#   [NAT GW in public-b]
#      |
#   private-b 10.42.10.0/24  <- EKS nodes
#   private-c 10.42.11.0/24  <- EKS nodes
#
# Note there is ONE NAT Gateway, in AZ-b. That means all egress from AZ-c nodes
# crosses AZs, and losing AZ-b kills internet egress for the whole cluster.
# That is a deliberate cost tradeoff ($0.045/hr instead of $0.090/hr).
# ---------------------------------------------------------------------------

resource "aws_vpc" "main" {
  cidr_block = var.vpc_cidr

  # Both required for EKS: pods resolve internal service names via VPC DNS.
  enable_dns_support   = true
  enable_dns_hostnames = true

  tags = { Name = var.name }
}

resource "aws_internet_gateway" "main" {
  vpc_id = aws_vpc.main.id
  tags   = { Name = var.name }
}

# --- Public subnets ---------------------------------------------------------

resource "aws_subnet" "public" {
  count = length(var.azs)

  vpc_id                  = aws_vpc.main.id
  cidr_block              = var.public_subnet_cidrs[count.index]
  availability_zone       = var.azs[count.index]
  map_public_ip_on_launch = true

  tags = merge(local.cluster_tag, {
    Name = "${var.name}-public-${var.azs[count.index]}"
    # Tells the AWS Load Balancer Controller "put internet-facing ALBs here".
    "kubernetes.io/role/elb" = "1"
  })
}

# --- Private subnets --------------------------------------------------------

resource "aws_subnet" "private" {
  count = length(var.azs)

  vpc_id            = aws_vpc.main.id
  cidr_block        = var.private_subnet_cidrs[count.index]
  availability_zone = var.azs[count.index]

  tags = merge(local.cluster_tag, {
    Name = "${var.name}-private-${var.azs[count.index]}"
    # Tells the controller "put internal ALBs/NLBs here".
    "kubernetes.io/role/internal-elb" = "1"
  })
}

# --- NAT Gateway (single, in the first AZ) ----------------------------------

resource "aws_eip" "nat" {
  domain = "vpc"
  tags   = { Name = "${var.name}-nat" }
}

resource "aws_nat_gateway" "main" {
  allocation_id = aws_eip.nat.id
  subnet_id     = aws_subnet.public[0].id
  tags          = { Name = "${var.name}-nat" }

  # An IGW must exist before a NAT Gateway can be usable.
  depends_on = [aws_internet_gateway.main]
}

# --- Route tables -----------------------------------------------------------

resource "aws_route_table" "public" {
  vpc_id = aws_vpc.main.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.main.id
  }

  tags = { Name = "${var.name}-public" }
}

resource "aws_route_table_association" "public" {
  count          = length(aws_subnet.public)
  subnet_id      = aws_subnet.public[count.index].id
  route_table_id = aws_route_table.public.id
}

# One shared private route table, because there is only one NAT Gateway.
# (With one NAT per AZ you would need one route table per AZ.)
resource "aws_route_table" "private" {
  vpc_id = aws_vpc.main.id

  route {
    cidr_block     = "0.0.0.0/0"
    nat_gateway_id = aws_nat_gateway.main.id
  }

  tags = { Name = "${var.name}-private" }
}

resource "aws_route_table_association" "private" {
  count          = length(aws_subnet.private)
  subnet_id      = aws_subnet.private[count.index].id
  route_table_id = aws_route_table.private.id
}

# --- S3 Gateway endpoint ----------------------------------------------------
# Free, and keeps S3 traffic (notably ECR layer downloads, which are stored in
# S3) off the NAT Gateway. Saves real money on data processing charges during
# image pulls.

resource "aws_vpc_endpoint" "s3" {
  vpc_id            = aws_vpc.main.id
  service_name      = "com.amazonaws.${var.region}.s3"
  vpc_endpoint_type = "Gateway"
  route_table_ids   = [aws_route_table.private.id]

  tags = { Name = "${var.name}-s3" }
}
