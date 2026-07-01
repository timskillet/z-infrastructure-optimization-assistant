terraform {
  required_providers {
    ibm = {
      source  = "IBM-Cloud/ibm"
      version = "~> 1.67.0"
    }
  }
  required_version = ">= 1.0"
}

provider "ibm" {
  region = var.ibm_region
  # Auth: set IC_API_KEY env var (ibmcloud iam api-key-create terraform-key --output JSON)
}

# ---------------------------------------------------------------------------
# Variables
# ---------------------------------------------------------------------------

variable "ibm_region" {
  description = "IBM Cloud region"
  type        = string
  default     = "us-south"

  validation {
    condition     = var.ibm_region == "us-south"
    error_message = "Only us-south is supported; instance_image default is region-specific."
  }
}

variable "instance_name" {
  description = "Name of the VSI instance"
  type        = string
  default     = "z-optimization-agent"
}

variable "instance_profile" {
  description = "Instance profile — matches live (2 vCPU, 8 GB RAM)"
  type        = string
  default     = "bxf-2x8"
}

variable "instance_image" {
  description = "ibm-ubuntu-24-04-4-minimal-amd64-5 in us-south"
  type        = string
  default     = "r006-180f08ca-bac4-4452-926a-65decf99b022"
}

variable "ssh_key_name" {
  description = "Name of existing SSH key in IBM Cloud"
  type        = string
}

variable "ssh_allowed_cidr" {
  description = "CIDR allowed to reach SSH (port 22). Restrict to your IP in production."
  type        = string
  default     = "0.0.0.0/0"
}

# ---------------------------------------------------------------------------
# Data sources — resources provisioned via console, not managed here
# ---------------------------------------------------------------------------

data "ibm_resource_group" "default" {
  name = "Default"
}

# VPC created by IBM Cloud console (Cloud Foundation for VPC)
data "ibm_is_vpc" "z_vpc" {
  name = "us-south-default-vpc-07010146"
}

# Default subnet in us-south-1
data "ibm_is_subnet" "z_subnet" {
  name = "us-south-1-default-subnet"
}

# Default security group attached to the VPC
data "ibm_is_security_group" "z_sg" {
  name = "steerable-diligent-silicon-residence"
}

data "ibm_is_ssh_key" "ssh_key" {
  name = var.ssh_key_name
}

# Floating IP provisioned via console
data "ibm_is_floating_ip" "z_floating_ip" {
  name = "z-optimization-public-ip"
}

# ---------------------------------------------------------------------------
# VSI instance
# Provisioned via console — import before first apply:
#   terraform import ibm_is_instance.z_instance 0717_d8416df3-e41c-481c-97ee-d2375b67d898
# After import, run `terraform plan` and verify no -/+ (destroy/recreate) diffs
# before applying. Fields like image, vpc, zone, and primary_network_interface
# are ForceNew — any drift from the console config will trigger replacement.
# ---------------------------------------------------------------------------

resource "ibm_is_instance" "z_instance" {
  name           = var.instance_name
  vpc            = data.ibm_is_vpc.z_vpc.id
  zone           = "${var.ibm_region}-1"
  image          = var.instance_image
  profile        = var.instance_profile
  resource_group = data.ibm_resource_group.default.id

  primary_network_interface {
    subnet          = data.ibm_is_subnet.z_subnet.id
    security_groups = [data.ibm_is_security_group.z_sg.id]
  }

  keys = [data.ibm_is_ssh_key.ssh_key.id]

  boot_volume {
    size = 100
  }

  tags = ["z-optimization", "terraform"]
}

# ---------------------------------------------------------------------------
# Security group rules
# Applied to the existing default SG — Terraform will add these rules.
# ---------------------------------------------------------------------------

resource "ibm_is_security_group_rule" "allow_ssh" {
  group     = data.ibm_is_security_group.z_sg.id
  direction = "inbound"
  remote    = var.ssh_allowed_cidr
  tcp {
    port_min = 22
    port_max = 22
  }
}

# FastAPI backend
resource "ibm_is_security_group_rule" "allow_fastapi" {
  group     = data.ibm_is_security_group.z_sg.id
  direction = "inbound"
  remote    = "0.0.0.0/0"
  tcp {
    port_min = 8000
    port_max = 8000
  }
}

# Streamlit UI
resource "ibm_is_security_group_rule" "allow_streamlit" {
  group     = data.ibm_is_security_group.z_sg.id
  direction = "inbound"
  remote    = "0.0.0.0/0"
  tcp {
    port_min = 8501
    port_max = 8501
  }
}

# All outbound — covers zOSMF (6443), Db2, Claude API, IBM COS, etc.
resource "ibm_is_security_group_rule" "allow_outbound_all" {
  group     = data.ibm_is_security_group.z_sg.id
  direction = "outbound"
  remote    = "0.0.0.0/0"
}

# ---------------------------------------------------------------------------
# Object Storage — RAG corpus, model checkpoints, execution traces
# ---------------------------------------------------------------------------

resource "ibm_resource_instance" "cos_instance" {
  name              = "z-optimization-storage"
  resource_group_id = data.ibm_resource_group.default.id
  service           = "cloud-object-storage"
  plan              = "lite"
  location          = "global"
  tags              = ["z-optimization"]
}

resource "ibm_cos_bucket" "z_documentation" {
  bucket_name          = "z-opt-docs-${substr(data.ibm_resource_group.default.id, 0, 8)}"
  resource_instance_id = ibm_resource_instance.cos_instance.id
  region_location      = var.ibm_region
  storage_class        = "standard"
}

resource "ibm_cos_bucket" "models" {
  bucket_name          = "z-opt-models-${substr(data.ibm_resource_group.default.id, 0, 8)}"
  resource_instance_id = ibm_resource_instance.cos_instance.id
  region_location      = var.ibm_region
  storage_class        = "standard"
}

resource "ibm_cos_bucket" "traces" {
  bucket_name          = "z-opt-traces-${substr(data.ibm_resource_group.default.id, 0, 8)}"
  resource_instance_id = ibm_resource_instance.cos_instance.id
  region_location      = var.ibm_region
  storage_class        = "standard"
}

# ---------------------------------------------------------------------------
# Outputs
# ---------------------------------------------------------------------------

output "instance_id" {
  value       = ibm_is_instance.z_instance.id
  description = "VSI instance ID"
}

output "instance_private_ip" {
  value       = ibm_is_instance.z_instance.primary_network_interface[0].primary_ip[0].address
  description = "Private IP address"
}

output "public_ip" {
  value       = data.ibm_is_floating_ip.z_floating_ip.address
  description = "Public IP — use for SSH and API access"
}

output "ssh_command" {
  value       = "ssh -i /path/to/key ubuntu@${data.ibm_is_floating_ip.z_floating_ip.address}"
  description = "SSH command"
}

output "fastapi_url" {
  value       = "http://${data.ibm_is_floating_ip.z_floating_ip.address}:8000"
  description = "FastAPI backend URL"
}

output "streamlit_url" {
  value       = "http://${data.ibm_is_floating_ip.z_floating_ip.address}:8501"
  description = "Streamlit UI URL"
}

output "cos_instance_id" {
  value       = ibm_resource_instance.cos_instance.id
  description = "Object Storage instance CRN"
}

output "cos_docs_bucket" {
  value       = ibm_cos_bucket.z_documentation.bucket_name
  description = "RAG documentation bucket name"
}

output "cos_models_bucket" {
  value       = ibm_cos_bucket.models.bucket_name
  description = "Model checkpoints bucket name"
}

output "cos_traces_bucket" {
  value       = ibm_cos_bucket.traces.bucket_name
  description = "Execution traces bucket name"
}
