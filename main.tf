provider "aws" {
  region = "us-east-1"
}

resource "aws_ecr_repository" "my_python_terraform_app" {
  name = "my-python-terraform-app"
}

resource "aws_iam_role" "ecs_task_execution_terraform_role" {
  name = "ecsTaskExecutionTerraformRole"
  assume_role_policy = jsonencode({
    Version = "2012-10-17",
    Statement = [
      {
        Effect = "Allow",
        Principal = {
          Service = "ecs-tasks.amazonaws.com"
        },
        Action = "sts:AssumeRole"
      }
    ]
  })
}

resource "aws_iam_policy_attachment" "ecs_task_execution_role_terraform_policy" {
  name       = "ecs_task_execution_role_terraform_policy"
  roles      = [aws_iam_role.ecs_task_execution_terraform_role.name]
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy"
}


resource "aws_ecs_cluster" "main" {
  name = "my-terraform-cluster"
}

resource "aws_ecs_task_definition" "main" {
  family                   = "my-terraform-task"
  requires_compatibilities = ["FARGATE"]
  network_mode             = "awsvpc"
  cpu                      = "256"
  memory                   = "512"

  execution_role_arn = aws_iam_role.ecs_task_execution_terraform_role.arn
  container_definitions = jsonencode([
    {
      name      = "my-container-terraform-app"
      image     = "${aws_ecr_repository.my_python_terraform_app.repository_url}:latest"
      essential = true
      portMappings = [
        {
          containerPort = 8000
          hostPort      = 8000
        }
      ]
    }
  ])
}

resource "aws_security_group" "lb_tf_sg" {
  name        = "lb-terraform-security-group"
  description = "Security group for the load balancer"
  vpc_id      = "vpc-0b8ab94a3a1d81680"

  ingress {
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    from_port   = 8000
    to_port     = 8000
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "lb-terraform-security-group"
  }
}

resource "aws_lb" "main" {
  name               = "my-terraform-lb"
  internal           = false
  load_balancer_type = "application"
  security_groups    = [aws_security_group.lb_tf_sg.id]
  subnets            = ["subnet-0249a457f7d1f4be6", "subnet-03d27086196538807"]

  enable_deletion_protection = false

  tags = {
    Name = "my-terraform-lb"
  }
}


# Primary Target Group
resource "aws_lb_target_group" "primary" {
  name        = "my-primary-target-group"
  port        = 8000
  protocol    = "HTTP"
  target_type = "ip"
  vpc_id      = "vpc-0b8ab94a3a1d81680"

  health_check {
    path                = "/health"
    interval            = 30
    timeout             = 5
    healthy_threshold   = 5
    unhealthy_threshold = 2
    matcher             = "200"
  }

  tags = {
    Name = "my-primary-target-group"
  }
}

# Secondary Target Group
resource "aws_lb_target_group" "secondary" {
  name        = "my-secondary-target-group"
  port        = 8000
  protocol    = "HTTP"
  target_type = "ip"
  vpc_id      = "vpc-0b8ab94a3a1d81680"

  health_check {
    path                = "/health"
    interval            = 30
    timeout             = 5
    healthy_threshold   = 5
    unhealthy_threshold = 2
    matcher             = "200"
  }

  tags = {
    Name = "my-secondary-target-group"
  }
}

resource "aws_lb_listener" "http" {
  load_balancer_arn = aws_lb.main.arn
  port              = "80"
  protocol          = "HTTP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.primary.arn
  }
}


resource "aws_ecs_service" "main" {
  name            = "my-terraform-app-service"
  cluster         = aws_ecs_cluster.main.id
  task_definition = aws_ecs_task_definition.main.arn
  desired_count   = 1
  launch_type     = "FARGATE"

  deployment_controller {
    type = "CODE_DEPLOY"
  }

  network_configuration {
    subnets          = ["subnet-0249a457f7d1f4be6", "subnet-03d27086196538807"]
    security_groups  = [aws_security_group.lb_tf_sg.id]
    assign_public_ip = true
  }

  load_balancer {
    target_group_arn = aws_lb_target_group.primary.arn
    container_name   = "my-container-terraform-app"
    container_port   = 8000
  }

  tags = {
    Name = "my-terraform-app-service"
  }
}


resource "aws_codebuild_project" "my_python_terraform_app" {
  name          = "my-python-terraform-app"
  description   = "Build project for my Python app"
  build_timeout = "5"
  service_role  = aws_iam_role.codebuild_terraform_role.arn

  artifacts {
    type = "CODEPIPELINE"
  }

  environment {
    compute_type    = "BUILD_GENERAL1_SMALL"
    image           = "aws/codebuild/standard:5.0"
    type            = "LINUX_CONTAINER"
    privileged_mode = true
  }

  source {
    type      = "CODEPIPELINE"
    buildspec = "buildspec.yml"
  }
}

resource "aws_codedeploy_app" "my_terraform_app" {
  compute_platform = "ECS"
  name             = "my-terraform-app"
}

resource "aws_codedeploy_deployment_group" "my_terraform_app" {
  app_name               = aws_codedeploy_app.my_terraform_app.name
  deployment_config_name = "CodeDeployDefault.ECSAllAtOnce"
  deployment_group_name  = "my-terraform-app-deployment-group"
  service_role_arn       = aws_iam_role.codedeploy_terraform_role.arn

  auto_rollback_configuration {
    enabled = true
    events  = ["DEPLOYMENT_FAILURE"]
  }

  blue_green_deployment_config {
    deployment_ready_option {
      action_on_timeout = "CONTINUE_DEPLOYMENT"
    }

    terminate_blue_instances_on_deployment_success {
      action                           = "TERMINATE"
      termination_wait_time_in_minutes = 5
    }
  }

  deployment_style {
    deployment_option = "WITH_TRAFFIC_CONTROL"
    deployment_type   = "BLUE_GREEN"
  }

  ecs_service {
    cluster_name = aws_ecs_cluster.main.name
    service_name = aws_ecs_service.main.name
  }

  load_balancer_info {
    target_group_pair_info {
      prod_traffic_route {
        listener_arns = [aws_lb_listener.http.arn]
      }

      target_group {
        name = aws_lb_target_group.primary.name
      }

      target_group {
        name = aws_lb_target_group.secondary.name
      }
    }
  }
}

resource "aws_iam_role" "codedeploy_terraform_role" {
  name = "codedeploy-terraform-role"
  assume_role_policy = jsonencode({
    Version = "2012-10-17",
    Statement = [
      {
        Effect = "Allow",
        Principal = {
          Service = "codedeploy.amazonaws.com"
        },
        Action = "sts:AssumeRole"
      }
    ]
  })
}

resource "aws_iam_policy_attachment" "codedeploy_terraform_role_policy" {
  name       = "codedeploy_terraform_role_policy"
  roles      = [aws_iam_role.codedeploy_terraform_role.name]
  policy_arn = "arn:aws:iam::aws:policy/AWSCodeDeployRoleForECS"
}

# S3 Bucket for CodePipeline Artifacts
resource "aws_s3_bucket" "main" {
  bucket = "my-tf-codepipeline-bucket"
}

resource "aws_s3_bucket_ownership_controls" "main" {
  bucket = aws_s3_bucket.main.id
  rule {
    object_ownership = "BucketOwnerPreferred"
  }
}

resource "aws_s3_bucket_acl" "main" {
  depends_on = [aws_s3_bucket_ownership_controls.main]

  bucket = aws_s3_bucket.main.id
  acl    = "private"
}


# IAM Role for CodePipeline
resource "aws_iam_role" "codepipeline_terraform_role" {
  name = "codepipeline-terraform-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17",
    Statement = [{
      Effect = "Allow",
      Principal = {
        Service = "codepipeline.amazonaws.com"
      },
      Action = "sts:AssumeRole"
    }]
  })

  inline_policy {
    name = "codepipeline-policy"
    policy = jsonencode({
      Version = "2012-10-17",
      Statement = [
        {
          Effect   = "Allow",
          Action   = ["s3:*"],
          Resource = ["${aws_s3_bucket.main.arn}", "${aws_s3_bucket.main.arn}/*"]
        },
        {
          Effect   = "Allow",
          Action   = ["codebuild:*"],
          Resource = "*"
        },
        {
          Effect   = "Allow",
          Action   = ["codedeploy:*"],
          Resource = "*"
        },
        {
          Effect   = "Allow",
          Action   = ["iam:PassRole"],
          Resource = "*"
        }
      ]
    })
  }
}

# IAM Role for CodeBuild
resource "aws_iam_role" "codebuild_terraform_role" {
  name = "codebuild-terraform-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17",
    Statement = [{
      Effect = "Allow",
      Principal = {
        Service = "codebuild.amazonaws.com"
      },
      Action = "sts:AssumeRole"
    }]
  })

  inline_policy {
    name = "codebuild-policy"
    policy = jsonencode({
      Version = "2012-10-17",
      Statement = [
        {
          Effect   = "Allow",
          Action   = ["ecr:GetDownloadUrlForLayer", "ecr:BatchGetImage", "ecr:BatchCheckLayerAvailability"],
          Resource = "*"
        },
        {
          Effect   = "Allow",
          Action   = ["logs:*"],
          Resource = "*"
        },
        {
          Effect   = "Allow",
          Action   = ["s3:*"],
          Resource = ["${aws_s3_bucket.main.arn}", "${aws_s3_bucket.main.arn}/*"]
        },
        {
          Effect   = "Allow",
          Action   = ["ecs:*"],
          Resource = "*"
        },
        {
          Effect   = "Allow",
          Action   = ["codedeploy:*"],
          Resource = "*"
        },
        {
          Effect   = "Allow",
          Action   = ["iam:PassRole"],
          Resource = "*"
        }
      ]
    })
  }

  managed_policy_arns = [
    "arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryPowerUser"
  ]
}



resource "aws_codepipeline" "main" {
  name     = "my-terraform-app-pipeline"
  role_arn = aws_iam_role.codepipeline_terraform_role.arn

  artifact_store {
    location = aws_s3_bucket.main.bucket
    type     = "S3"
  }

  stage {
    name = "Source"

    action {
      name             = "Source"
      category         = "Source"
      owner            = "ThirdParty"
      provider         = "GitHub"
      version          = "1"
      output_artifacts = ["source_output"]

      configuration = {
        Owner      = "rakshanivasini"
        Repo       = "python-app-cicd-task"
        Branch     = "main"
        OAuthToken = ""
      }
    }
  }

  stage {
    name = "Build"

    action {
      name             = "Build"
      category         = "Build"
      owner            = "AWS"
      provider         = "CodeBuild"
      input_artifacts  = ["source_output"]
      output_artifacts = ["build_output"]
      version          = "1"

      configuration = {
        ProjectName = aws_codebuild_project.my_python_terraform_app.name
      }
    }
  }

  stage {
    name = "Deploy"

    action {
      name            = "Deploy"
      category        = "Deploy"
      owner           = "AWS"
      provider        = "CodeDeploy"
      input_artifacts = ["build_output"]
      version         = "1"

      configuration = {
        ApplicationName     = aws_codedeploy_app.my_terraform_app.name
        DeploymentGroupName = aws_codedeploy_deployment_group.my_terraform_app.deployment_group_name
      }
    }
  }
}
