variable "region" {
  description = "AWS region. Jakarta - chosen because the shared sandbox account lives here."
  type        = string
  default     = "ap-southeast-3"
}

variable "name" {
  description = "Name prefix for every resource. Must be unique - this account already hosts ~25 other learners' clusters."
  type        = string
  default     = "l2lab-sawibowo"
}

variable "owner" {
  description = "Tag applied to everything, so you (and the sandbox admins) can tell your resources from everyone else's."
  type        = string
  default     = "sawibowo"
}

# --- Networking -------------------------------------------------------------

variable "vpc_cidr" {
  description = "Deliberately an unusual /16 so it will not collide with the 52 other VPCs in this account."
  type        = string
  default     = "10.42.0.0/16"
}

variable "azs" {
  description = <<-EOT
    Two AZs only (cost). Note we skip ap-southeast-3a on purpose: spot for t4g.large
    was $0.0385/hr there versus $0.0274 (3b) and $0.0263 (3c) - roughly 46% more expensive.
  EOT
  type        = list(string)
  default     = ["ap-southeast-3b", "ap-southeast-3c"]
}

variable "public_subnet_cidrs" {
  description = "Holds the ALB and the NAT Gateway."
  type        = list(string)
  default     = ["10.42.0.0/24", "10.42.1.0/24"]
}

variable "private_subnet_cidrs" {
  description = "Holds the EKS worker nodes. No route to the internet except via the NAT Gateway."
  type        = list(string)
  default     = ["10.42.10.0/24", "10.42.11.0/24"]
}

# --- Cluster ----------------------------------------------------------------

variable "cluster_version" {
  description = <<-EOT
    Must stay on an EKS version in STANDARD support. Versions in EXTENDED support
    (1.33 and below as of Aug 2026) cost $0.60/hr for the control plane instead of
    $0.10/hr - a 6x increase on the single largest line item in this stack.
  EOT
  type        = string
  default     = "1.34"
}

variable "node_instance_types" {
  description = <<-EOT
    Graviton (arm64). Cheaper than x86 equivalents, and builds natively on an
    Apple Silicon Mac with no QEMU emulation. Multiple types listed so the spot
    request can fall back rather than fail if one pool is exhausted.
  EOT
  type        = list(string)
  default     = ["t4g.large", "t4g.xlarge", "m7g.large"]
}

variable "node_desired_size" {
  type    = number
  default = 2
}

variable "node_min_size" {
  type    = number
  default = 2
}

variable "node_max_size" {
  description = "Headroom for a spot interruption or a rollout, without paying for it at rest."
  type        = number
  default     = 3
}

# --- DNS / TLS --------------------------------------------------------------

variable "parent_zone_name" {
  description = "Pre-existing Route53 public zone shared by all learners in this account."
  type        = string
  default     = "sandbox.devopsinstitute.id"
}

variable "subdomain" {
  description = "Your slice of the shared zone. Produces app.<subdomain> and grafana.<subdomain>."
  type        = string
  default     = "sawibowo"
}

# --- Production hardening switches -------------------------------------------
# Each of these is production-correct but costs money or convenience, so they
# are variables with lab-appropriate defaults rather than hard-coded choices.

variable "backup_retention_days" {
  description = "How long database dumps live in S3."
  type        = number
  default     = 7
}

variable "enable_audit_logs" {
  description = <<-EOT
    Ship the Kubernetes audit log to CloudWatch. Production: yes, always - it is
    how you answer "who deleted that". Default off here because audit logs are
    very chatty and CloudWatch ingestion is $0.50/GB, which for this cluster is
    roughly $0.50-1.00/day for data you will probably never read.
  EOT
  type        = bool
  default     = false
}

variable "enable_flow_logs" {
  description = <<-EOT
    VPC Flow Logs to S3. Production: yes - they are how you prove whether
    traffic ever reached an instance during a connectivity incident. Off by
    default here purely to keep the lab bill near zero.
  EOT
  type        = bool
  default     = false
}

variable "api_public_access_cidrs" {
  description = <<-EOT
    Who may reach the EKS API server endpoint. Production should be a short
    list of office/VPN ranges, or private-only access with a bastion.
    0.0.0.0/0 is the default here so kubectl works from wherever you are -
    the API still requires IAM authentication, but this is a real, deliberate
    weakening. Set it to ["<your-ip>/32"] to close it down.
  EOT
  type        = list(string)
  default     = ["0.0.0.0/0"]
}
