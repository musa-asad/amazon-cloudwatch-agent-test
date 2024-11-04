// Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
// SPDX-License-Identifier: MIT

module "common" {
  source = "../../../common"
}

module "basic_components" {
  source = "../../../basic_components"
}

locals {
  aws_eks      = "aws eks --region ${var.region}"
  cluster_name = var.cluster_name != "" ? var.cluster_name : "cwagent-otel-config-e2e-eks"
}

data "aws_eks_cluster_auth" "this" {
  name = aws_eks_cluster.this.name
}

resource "aws_eks_cluster" "this" {
  name     = "${local.cluster_name}-${module.common.testing_id}"
  role_arn = module.basic_components.role_arn
  version  = var.k8s_version
  vpc_config {
    subnet_ids         = module.basic_components.public_subnet_ids
    security_group_ids = [module.basic_components.security_group]
  }
}

resource "aws_eks_node_group" "this" {
  cluster_name    = aws_eks_cluster.this.name
  node_group_name = "${local.cluster_name}-node"
  node_role_arn   = aws_iam_role.node_role.arn
  subnet_ids      = module.basic_components.public_subnet_ids

  scaling_config {
    desired_size = 1
    max_size     = 1
    min_size     = 1
  }

  ami_type       = "AL2_x86_64"
  capacity_type  = "ON_DEMAND"
  disk_size      = 20
  instance_types = ["t3a.medium"]

  depends_on = [
    aws_iam_role_policy_attachment.node_CloudWatchAgentServerPolicy,
    aws_iam_role_policy_attachment.node_AmazonEC2ContainerRegistryReadOnly,
    aws_iam_role_policy_attachment.node_AmazonEKS_CNI_Policy,
    aws_iam_role_policy_attachment.node_AmazonEKSWorkerNodePolicy
  ]
}

resource "aws_iam_role" "node_role" {
  name = "${local.cluster_name}-Worker-Role-${module.common.testing_id}"

  assume_role_policy = <<POLICY
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Principal": {
        "Service": "ec2.amazonaws.com"
      },
      "Action": "sts:AssumeRole"
    }
  ]
}
POLICY
}

resource "aws_iam_role_policy_attachment" "node_AmazonEKSWorkerNodePolicy" {
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKSWorkerNodePolicy"
  role       = aws_iam_role.node_role.name
}

resource "aws_iam_role_policy_attachment" "node_AmazonEKS_CNI_Policy" {
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKS_CNI_Policy"
  role       = aws_iam_role.node_role.name
}

resource "aws_iam_role_policy_attachment" "node_AmazonEC2ContainerRegistryReadOnly" {
  policy_arn = "arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryReadOnly"
  role       = aws_iam_role.node_role.name
}

resource "aws_iam_role_policy_attachment" "node_CloudWatchAgentServerPolicy" {
  policy_arn = "arn:aws:iam::aws:policy/CloudWatchAgentServerPolicy"
  role       = aws_iam_role.node_role.name
}

resource "null_resource" "kubectl" {
  depends_on = [
    aws_eks_cluster.this,
    aws_eks_node_group.this
  ]
  provisioner "local-exec" {
    command = <<-EOT
      ${local.aws_eks} update-kubeconfig --name ${aws_eks_cluster.this.name}
      ${local.aws_eks} list-clusters --output text
      ${local.aws_eks} describe-cluster --name ${aws_eks_cluster.this.name} --output text
    EOT
  }
}

data "http" "values_yaml" {
  url = "https://raw.githubusercontent.com/aws-observability/helm-charts/${var.helm_charts_branch}/charts/amazon-cloudwatch-observability/values.yaml"
}

resource "null_resource" "helm_charts" {
  provisioner "local-exec" {
    command = <<-EOT
      git clone https://github.com/aws-observability/helm-charts.git helm-charts
      cd helm-charts
      git checkout ${var.helm_charts_branch}
    EOT
  }

  provisioner "local-exec" {
    when    = destroy
    command = "rm -rf ${path.module}/helm-charts"
  }
}

resource "helm_release" "otel-configuration" {
  depends_on = [
    null_resource.kubectl,
    null_resource.helm_charts,
    null_resource.amazon-cloudwatch-agent,
    null_resource.amazon-cloudwatch-agent-operator
  ]

  chart = "${path.module}/helm-charts/charts/amazon-cloudwatch-observability"

  values = [
    data.http.values_yaml.response_body
  ]

  name             = "amazon-cloudwatch-observability"
  namespace        = "amazon-cloudwatch"
  create_namespace = true

  set {
    name  = "region"
    value = var.region
  }

  set {
    name  = "clusterName"
    value = aws_eks_cluster.this.name
  }

  set {
    name  = "agent.image.repository"
    value = ""
  }

  set {
    name  = "agent.image.tag"
    value = module.common.testing_id
  }

  set {
    name  = "agent.image.repositoryDomainMap.public"
    value = aws_ecr_repository.cloudwatch_agent.repository_url
  }

  set {
    name  = "manager.image.repository"
    value = ""
  }

  set {
    name  = "manager.image.tag"
    value = module.common.testing_id
  }

  set {
    name  = "manager.image.repositoryDomainMap.public"
    value = aws_ecr_repository.cloudwatch_agent_operator.repository_url
  }

  set {
    name = "agent.otelConfig"
    value = file(var.otel-config)
  }
}

resource "aws_ecr_repository" "cloudwatch_agent" {
  name                 = "cloudwatch-agent-${module.common.testing_id}"
  image_tag_mutability = "MUTABLE"
  force_delete         = true

  image_scanning_configuration {
    scan_on_push = true
  }
}

resource "null_resource" "amazon-cloudwatch-agent" {
  triggers = {
    testing_id = module.common.testing_id
    ecr_url    = aws_ecr_repository.cloudwatch_agent.repository_url
  }

  provisioner "local-exec" {
    command = <<-EOT
      git clone https://github.com/aws/amazon-cloudwatch-agent.git amazon-cloudwatch-agent
      cd amazon-cloudwatch-agent
      git checkout ${var.agent_branch}
      make amazon-cloudwatch-agent-linux
      make docker-build-amd64 IMAGE=amazon-cloudwatch-agent:${module.common.testing_id}

      aws ecr get-login-password --region ${var.region} | docker login --username AWS --password-stdin ${aws_ecr_repository.cloudwatch_agent.repository_url}
      docker tag amazon-cloudwatch-agent:${module.common.testing_id} ${aws_ecr_repository.cloudwatch_agent.repository_url}:${module.common.testing_id}
      docker push ${aws_ecr_repository.cloudwatch_agent.repository_url}:${module.common.testing_id}
    EOT
  }

  provisioner "local-exec" {
    when    = destroy
    command = <<-EOT
      rm -rf ${path.module}/amazon-cloudwatch-agent
      docker rmi amazon-cloudwatch-agent:${self.triggers.testing_id} || true
      docker rmi ${self.triggers.ecr_url}:${self.triggers.testing_id} || true
    EOT
  }

  depends_on = [aws_ecr_repository.cloudwatch_agent]
}

resource "aws_ecr_repository" "cloudwatch_agent_operator" {
  name                 = "cloudwatch-agent-operator-${module.common.testing_id}"
  image_tag_mutability = "MUTABLE"
  force_delete         = true

  image_scanning_configuration {
    scan_on_push = true
  }
}

resource "null_resource" "amazon-cloudwatch-agent-operator" {
  triggers = {
    testing_id = module.common.testing_id
    ecr_url    = aws_ecr_repository.cloudwatch_agent_operator.repository_url
  }

  provisioner "local-exec" {
    command = <<-EOT
      git clone https://github.com/aws/amazon-cloudwatch-agent-operator.git amazon-cloudwatch-agent-operator
      cd amazon-cloudwatch-agent-operator
      git checkout ${var.operator_branch}
      make container IMG=amazon-cloudwatch-agent-operator:${module.common.testing_id}

      aws ecr get-login-password --region ${var.region} | docker login --username AWS --password-stdin ${aws_ecr_repository.cloudwatch_agent_operator.repository_url}
      docker tag amazon-cloudwatch-agent-operator:${module.common.testing_id} ${aws_ecr_repository.cloudwatch_agent_operator.repository_url}:${module.common.testing_id}
      docker push ${aws_ecr_repository.cloudwatch_agent_operator.repository_url}:${module.common.testing_id}
    EOT
  }

  provisioner "local-exec" {
    when    = destroy
    command = <<-EOT
      rm -rf ${path.module}/amazon-cloudwatch-agent-operator
      docker rmi amazon-cloudwatch-agent-operator:${self.triggers.testing_id} || true
      docker rmi ${self.triggers.ecr_url}:${self.triggers.testing_id} || true
    EOT
  }

  depends_on = [aws_ecr_repository.cloudwatch_agent_operator]
}