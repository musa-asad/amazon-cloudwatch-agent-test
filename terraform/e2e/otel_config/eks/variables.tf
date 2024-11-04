// Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
// SPDX-License-Identifier: MIT

variable "region" {
  type    = string
  default = "us-west-2"
}

variable "k8s_version" {
  type    = string
  default = "1.31"
}

variable "cluster_name" {
  type    = string
  default = "cwagent-otel-config-e2e-eks"
}

variable "agent_branch" {
  type    = string
  default = "main"
}

variable "operator_branch" {
  type    = string
  default = "main"
}

variable "helm_charts_branch" {
  type    = string
  default = "main"
}

variable "otel-config" {
  type = string
  default = "../files/otel_configs/otel-config.yaml"
}