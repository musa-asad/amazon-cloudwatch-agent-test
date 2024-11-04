variable "region" {
  type    = string
  default = "us-west-2"
}

variable "otlp_endpoint" {
  description = "OTLP endpoint for CloudWatch agent"
  default     = "0.0.0.0"
}

variable "ec2_instance_type" {
  type    = string
  default = "t3a.xlarge"
}

variable "agent_branch" {
  type    = string
  default = "main"
}

variable "otel-config" {
  type = string
  default = "../files/otel_configs/otel-config.yaml"
}