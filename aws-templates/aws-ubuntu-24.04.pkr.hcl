packer {
  required_plugins {
    amazon = {
      source  = "github.com/hashicorp/amazon"
      version = "~> 1.2.8"
    }
  }
}

# Variables
variable "aws_region" {
  type        = string
  default     = "ap-southeast-1"
  description = "AWS region to build the AMI"
}

variable "instance_type" {
  type        = string
  default     = "m5.large"
  description = "Instance type for building the AMI"
}

variable "spot_price" {
  type        = string
  default     = "0.05"
  description = "Maximum spot price for building instance"
}

variable "ami_name_prefix" {
  type        = string
  default     = "ydt-github-runner-ubuntu-24.04"
  description = "Prefix for the AMI name"
}

variable "runner_images_repo_path" {
  type        = string
  default     = "/tmp/runner-images"
  description = "Path where runner-images repository will be cloned"
}

locals {
  timestamp = regex_replace(timestamp(), "[- TZ:]", "")
  ami_name  = "${var.ami_name_prefix}-${local.timestamp}"
}

# Data sources
data "amazon-ami" "base_ami" {
  filters = {
    name                = "ubuntu/images/hvm-ssd/ubuntu-noble-24.04-amd64-server-*"
    root-device-type    = "ebs"
    virtualization-type = "hvm"
  }
  most_recent = true
  owners      = ["099720109477"] # Canonical
  region      = var.aws_region
}

# Build configuration
source "amazon-ebs" "ubuntu_2404" {
  ami_name                    = local.ami_name
  ami_description             = "YDT GitHub Actions Runner - Ubuntu 24.04 with pre-installed tools"
  instance_type              = var.instance_type
  region                      = var.aws_region
  source_ami                  = data.amazon-ami.base_ami.id
  ssh_username                = "ubuntu"
  temporary_key_pair_type     = "ed25519"
  
  # Spot instance configuration for cost optimization
  spot_price                  = var.spot_price
  spot_instance_types         = [var.instance_type, "m5.xlarge", "m5a.large"]
  
  # EBS configuration
  ebs_optimized              = true
  encrypt_boot               = true
  
  # Launch template configuration
  launch_block_device_mappings {
    device_name           = "/dev/sda1"
    volume_size           = 75
    volume_type           = "gp3"
    iops                  = 3000
    throughput            = 125
    encrypted             = true
    delete_on_termination = true
  }

  # Security and networking
  associate_public_ip_address = true
  
  # Tags
  tags = {
    Name         = local.ami_name
    OS           = "Ubuntu"
    OSVersion    = "24.04"
    Purpose      = "GitHub-Actions-Runner"
    Project      = "YDT-GitHub-Actions"
    CreatedBy    = "Packer"
    BuildDate    = timestamp()
    BaseAMI      = data.amazon-ami.base_ami.id
  }

  # Shutdown behavior
  shutdown_behavior = "terminate"
}

# Build steps
build {
  name = "ubuntu-2404"
  sources = ["source.amazon-ebs.ubuntu_2404"]

  # Clone the official runner-images repository
  provisioner "shell" {
    inline = [
      "sudo apt-get update",
      "sudo apt-get install -y git",
      "git clone https://github.com/ydt-automation/ydt-runner-images.git ${var.runner_images_repo_path}",
      "cd ${var.runner_images_repo_path}",
      "git checkout main"  # or specific release tag
    ]
  }

  # Use the official image generation script
  provisioner "shell" {
    execute_command = "sudo -E sh '{{ .Path }}'"
    environment_vars = [
      "IMAGE_OS=ubuntu24",
      "IMAGE_VERSION=24.04",
      "AGENT_TOOLSDIRECTORY=/opt/hostedtoolcache",
      "RUN_VALIDATION_FLAG=false"
    ]
    inline = [
      "cd ${var.runner_images_repo_path}",
      "chmod +x images/ubuntu/scripts/installers/*.sh",
      "chmod +x images/ubuntu/scripts/helpers/*.sh",
      "./images/ubuntu/scripts/installers/preimagedata.sh",
      "./images/ubuntu/scripts/installers/configure-apt-mock.sh",
      "./images/ubuntu/scripts/installers/7-zip.sh",
      "./images/ubuntu/scripts/installers/ansible.sh",
      "./images/ubuntu/scripts/installers/azcopy.sh",
      "./images/ubuntu/scripts/installers/azure-cli.sh",
      "./images/ubuntu/scripts/installers/azure-devops-cli.sh",
      "./images/ubuntu/scripts/installers/bicep.sh",
      "./images/ubuntu/scripts/installers/build-essential.sh",
      "./images/ubuntu/scripts/installers/clang.sh",
      "./images/ubuntu/scripts/installers/cmake.sh",
      "./images/ubuntu/scripts/installers/codeql-bundle.sh",
      "./images/ubuntu/scripts/installers/containers.sh",
      "./images/ubuntu/scripts/installers/dotnetcore-sdk.sh",
      "./images/ubuntu/scripts/installers/docker.sh",
      "./images/ubuntu/scripts/installers/firefox.sh",
      "./images/ubuntu/scripts/installers/gcc.sh",
      "./images/ubuntu/scripts/installers/gfortran.sh",
      "./images/ubuntu/scripts/installers/git.sh",
      "./images/ubuntu/scripts/installers/github-cli.sh",
      "./images/ubuntu/scripts/installers/google-chrome.sh",
      "./images/ubuntu/scripts/installers/google-cloud-cli.sh",
      "./images/ubuntu/scripts/installers/haskell.sh",
      "./images/ubuntu/scripts/installers/heroku.sh",
      "./images/ubuntu/scripts/installers/hhvm.sh",
      "./images/ubuntu/scripts/installers/java-tools.sh",
      "./images/ubuntu/scripts/installers/kubernetes-tools.sh",
      "./images/ubuntu/scripts/installers/mesa.sh",
      "./images/ubuntu/scripts/installers/microsoft-edge.sh",
      "./images/ubuntu/scripts/installers/miniconda.sh",
      "./images/ubuntu/scripts/installers/mono.sh",
      "./images/ubuntu/scripts/installers/mysql.sh",
      "./images/ubuntu/scripts/installers/nodejs.sh",
      "./images/ubuntu/scripts/installers/nvm.sh",
      "./images/ubuntu/scripts/installers/php.sh",
      "./images/ubuntu/scripts/installers/postgresql.sh",
      "./images/ubuntu/scripts/installers/powershell.sh",
      "./images/ubuntu/scripts/installers/pulumi.sh",
      "./images/ubuntu/scripts/installers/python.sh",
      "./images/ubuntu/scripts/installers/ruby.sh",
      "./images/ubuntu/scripts/installers/rust.sh",
      "./images/ubuntu/scripts/installers/selenium.sh",
      "./images/ubuntu/scripts/installers/terraform.sh",
      "./images/ubuntu/scripts/installers/vcpkg.sh",
      "./images/ubuntu/scripts/installers/dpkg-config.sh",
      "./images/ubuntu/scripts/installers/cleanup.sh"
    ]
  }

  # Install GitHub Actions Runner
  provisioner "shell" {
    execute_command = "sudo -E sh '{{ .Path }}'"
    inline = [
      "mkdir -p /opt/hostedtoolcache",
      "chown runner:runner /opt/hostedtoolcache",
      "cd ${var.runner_images_repo_path}",
      "./images/ubuntu/scripts/installers/runner.sh"
    ]
  }

  # Copy post-generation scripts
  provisioner "shell" {
    execute_command = "sudo -E sh '{{ .Path }}'"
    inline = [
      "cp -r ${var.runner_images_repo_path}/images/ubuntu/assets/post-gen /opt/",
      "chmod +x /opt/post-gen/*.sh"
    ]
  }

  # Generate software report
  provisioner "shell" {
    environment_vars = [
      "IMAGE_OS=ubuntu24",
      "TOOLSET_FILE_PATH=${var.runner_images_repo_path}/images/ubuntu/toolsets/toolset-2404.json"
    ]
    inline = [
      "cd ${var.runner_images_repo_path}",
      "pwsh -File images/ubuntu/SoftwareReport/SoftwareReport.Generator.ps1 -OutputDirectory /tmp",
      "cat /tmp/Ubuntu-24.04-Readme.md"
    ]
  }

  # Final cleanup
  provisioner "shell" {
    execute_command = "sudo -E sh '{{ .Path }}'"
    inline = [
      "apt-get autoremove -y",
      "apt-get autoclean",
      "rm -rf /tmp/*",
      "rm -rf ${var.runner_images_repo_path}",
      "# Clear history and prepare for AMI",
      "rm -f /home/ubuntu/.bash_history",
      "rm -f /root/.bash_history",
      "history -c"
    ]
  }
}
