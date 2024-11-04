module "common" {
  source = "../../../common"
}

module "basic_components" {
  source = "../../../basic_components"
}

resource "aws_ecs_cluster" "cluster" {
  name = "${local.basename}-${module.common.testing_id}"
}

data "aws_ami" "latest" {
  most_recent = true
  owners      = ["amazon"]

  filter {
    name   = "name"
    values = ["amzn2-ami-ecs-hvm-*-x86_64-ebs"]
  }
}

resource "aws_launch_template" "cluster" {
  name          = "cluster-${aws_ecs_cluster.cluster.name}"
  image_id      = data.aws_ami.latest.image_id
  instance_type = var.ec2_instance_type

  vpc_security_group_ids = [module.basic_components.security_group]

  iam_instance_profile {
    name = module.basic_components.instance_profile
  }

  user_data = base64encode("#!/bin/bash\necho ECS_CLUSTER=${aws_ecs_cluster.cluster.name} >> /etc/ecs/ecs.config")

  metadata_options {
    http_endpoint               = "enabled"
    http_tokens                 = "required"
    http_put_response_hop_limit = 2
  }
}

resource "aws_autoscaling_group" "cluster" {
  name                = aws_ecs_cluster.cluster.name
  vpc_zone_identifier = module.basic_components.public_subnet_ids

  min_size         = 1
  max_size         = 1
  desired_capacity = 1

  launch_template {
    id      = aws_launch_template.cluster.id
    version = "$Latest"
  }

  tag {
    key                 = "ClusterName"
    value               = aws_ecs_cluster.cluster.name
    propagate_at_launch = true
  }

  tag {
    key                 = "AmazonECSManaged"
    value               = ""
    propagate_at_launch = true
  }

  tag {
    key                 = "BaseClusterName"
    value               = local.basename
    propagate_at_launch = true
  }
}

resource "aws_ecs_capacity_provider" "cluster" {
  name = aws_ecs_cluster.cluster.name

  auto_scaling_group_provider {
    auto_scaling_group_arn = aws_autoscaling_group.cluster.arn

    managed_scaling {
      status                    = "ENABLED"
      maximum_scaling_step_size = 1
      minimum_scaling_step_size = 1
      target_capacity           = 1
    }

  }
}

resource "aws_ecs_cluster_capacity_providers" "cluster" {
  cluster_name = aws_ecs_cluster.cluster.name

  capacity_providers = [aws_ecs_capacity_provider.cluster.name]

  default_capacity_provider_strategy {
    base              = 1
    weight            = 100
    capacity_provider = aws_ecs_capacity_provider.cluster.name
  }
}

resource "aws_cloudwatch_log_group" "log_group" {
  name = "cwagent-integ-test-log-group-${module.common.testing_id}"
}

locals {
  basename = "cwagent-otel-config-e2e-ecs"
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

resource "aws_ecs_task_definition" "cwagent_task_definition" {
  family                   = "cwagent-task-family-${module.common.testing_id}"
  network_mode             = "bridge"
  task_role_arn            = module.basic_components.role_arn
  execution_role_arn       = module.basic_components.role_arn
  cpu                      = 256
  memory                   = 2048
  requires_compatibilities = ["EC2"]
  container_definitions = jsonencode([
    {
      name  = "cloudwatch-agent"
      image = "${aws_ecr_repository.cloudwatch_agent.repository_url}:${module.common.testing_id}"
      logConfiguration = {
        logDriver = "awslogs"
        options = {
          awslogs-group         = aws_cloudwatch_log_group.log_group.name
          awslogs-region        = var.region
          awslogs-stream-prefix = module.common.testing_id
        }
      }
      environment = [
        {
          name = "CW_CONFIG_CONTENT"
          value = jsonencode({
            metrics = {
              metrics_collected = {
                cpu    = {}
                disk   = {}
                memory = {}
              }
            }
          })
        },
        {
          name = "CW_OTEL_CONFIG_CONTENT"
          value = file(var.otel-config)
        }
      ]
    }
  ])
  depends_on = [aws_cloudwatch_log_group.log_group, null_resource.amazon-cloudwatch-agent]
  volume {
    name      = "proc"
    host_path = "/proc"
  }
  volume {
    name      = "dev"
    host_path = "/dev"
  }
  volume {
    name      = "al1_cgroup"
    host_path = "/cgroup"
  }
  volume {
    name      = "al2_cgroup"
    host_path = "/sys/fs/cgroup"
  }
}

resource "aws_ecs_service" "cwagent_service" {
  name                   = "cwagent-service-${module.common.testing_id}"
  cluster                = aws_ecs_cluster.cluster.id
  task_definition        = aws_ecs_task_definition.cwagent_task_definition.arn
  launch_type            = "EC2"
  scheduling_strategy    = "DAEMON"
  enable_execute_command = true
  force_new_deployment   = true

  depends_on = [aws_ecs_task_definition.cwagent_task_definition]
}