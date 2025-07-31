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
  default     = "0.10"
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
    name                = "ubuntu/images/hvm-ssd-gp3/ubuntu-noble-24.04-amd64-server-*"
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
  region                      = var.aws_region
  source_ami                  = data.amazon-ami.base_ami.id
  ssh_username                = "ubuntu"
  temporary_key_pair_type     = "ed25519"
  
  # Spot instance configuration for cost optimization
  spot_price                  = var.spot_price
  spot_instance_types         = [var.instance_type, "m5.xlarge", "m5a.large", "m5a.xlarge", "m4.large", "m4.xlarge"]
  
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

  # Create image generation folders
  provisioner "shell" {
    execute_command = "sudo sh -c '{{ .Vars }} {{ .Path }}'"
    inline = [
      "mkdir -p /imagegeneration",
      "chmod 777 /imagegeneration"
    ]
  }

  # Copy helper scripts
  provisioner "shell" {
    execute_command = "sudo sh -c '{{ .Vars }} {{ .Path }}'"
    inline = [
      "cp -r ${var.runner_images_repo_path}/images/ubuntu/scripts/helpers /imagegeneration/",
      "chmod +x /imagegeneration/helpers/*.sh"
    ]
  }

  # Configure APT mock (must be run before other provisioners)
  provisioner "shell" {
    execute_command = "sudo sh -c '{{ .Vars }} {{ .Path }}'"
    inline = [
      "cd ${var.runner_images_repo_path}",
      "chmod +x ./images/ubuntu/scripts/build/configure-apt-mock.sh",
      "chmod +x ./images/ubuntu/scripts/build/*.sh",
      "./images/ubuntu/scripts/build/configure-apt-mock.sh"
    ]
  }

  # Install MS repos and configure APT
  provisioner "shell" {
    environment_vars = [
      "HELPER_SCRIPTS=/imagegeneration/helpers",
      "DEBIAN_FRONTEND=noninteractive"
    ]
    execute_command = "sudo sh -c '{{ .Vars }} {{ .Path }}'"
    inline = [
      "cd ${var.runner_images_repo_path}",
      "./images/ubuntu/scripts/build/install-ms-repos.sh",
      "./images/ubuntu/scripts/build/configure-apt-sources.sh",
      "./images/ubuntu/scripts/build/configure-apt.sh"
    ]
  }

  # Configure limits
  provisioner "shell" {
    execute_command = "sudo sh -c '{{ .Vars }} {{ .Path }}'"
    inline = [
      "cd ${var.runner_images_repo_path}",
      "./images/ubuntu/scripts/build/configure-limits.sh"
    ]
  }

  # Copy minimal required files
  provisioner "shell" {
    execute_command = "sudo sh -c '{{ .Vars }} {{ .Path }}'"
    inline = [
      "# Copy only essential installer scripts we're using",
      "mkdir -p /imagegeneration/installers",
      "cp ${var.runner_images_repo_path}/images/ubuntu/scripts/build/install-actions-cache.sh /imagegeneration/installers/",
      "cp ${var.runner_images_repo_path}/images/ubuntu/scripts/build/install-runner-package.sh /imagegeneration/installers/",
      "cp ${var.runner_images_repo_path}/images/ubuntu/scripts/build/install-git.sh /imagegeneration/installers/",
      "cp ${var.runner_images_repo_path}/images/ubuntu/scripts/build/install-github-cli.sh /imagegeneration/installers/",
      "cp ${var.runner_images_repo_path}/images/ubuntu/scripts/build/install-dotnetcore-sdk.sh /imagegeneration/installers/",
      "cp ${var.runner_images_repo_path}/images/ubuntu/scripts/build/install-docker.sh /imagegeneration/installers/",
      "chmod +x /imagegeneration/installers/*.sh"
    ]
  }

  # Configure image data
  provisioner "shell" {
    environment_vars = [
      "IMAGE_VERSION=24.04",
      "IMAGEDATA_FILE=/imagegeneration/imagedata.json"
    ]
    execute_command = "sudo sh -c '{{ .Vars }} {{ .Path }}'"
    inline = [
      "cd ${var.runner_images_repo_path}",
      "./images/ubuntu/scripts/build/configure-image-data.sh"
    ]
  }

  # Configure environment (AWS-specific version)
  provisioner "shell" {
    environment_vars = [
      "IMAGE_VERSION=24.04",
      "IMAGE_OS=ubuntu24",
      "HELPER_SCRIPTS=/imagegeneration/helpers"
    ]
    execute_command = "sudo sh -c '{{ .Vars }} {{ .Path }}'"
    inline = [
      "cd ${var.runner_images_repo_path}",
      "chmod +x ./images/ubuntu/scripts/build/configure-environment-aws.sh",
      "./images/ubuntu/scripts/build/configure-environment-aws.sh"
    ]
  }

  # Install vital packages
  provisioner "shell" {
    environment_vars = [
      "DEBIAN_FRONTEND=noninteractive",
      "HELPER_SCRIPTS=/imagegeneration/helpers",
      "INSTALLER_SCRIPT_FOLDER=/imagegeneration/installers"
    ]
    execute_command = "sudo sh -c '{{ .Vars }} {{ .Path }}'"
    inline = [
      "cd ${var.runner_images_repo_path}",
      "./images/ubuntu/scripts/build/install-apt-vital.sh"
    ]
  }

  # Install PowerShell
  provisioner "shell" {
    environment_vars = [
      "HELPER_SCRIPTS=/imagegeneration/helpers",
      "INSTALLER_SCRIPT_FOLDER=/imagegeneration/installers"
    ]
    execute_command = "sudo sh -c '{{ .Vars }} {{ .Path }}'"
    inline = [
      "cd ${var.runner_images_repo_path}",
      "./images/ubuntu/scripts/build/install-powershell.sh"
    ]
  }

  # Install PowerShell modules
  provisioner "shell" {
    environment_vars = [
      "HELPER_SCRIPTS=/imagegeneration/helpers",
      "INSTALLER_SCRIPT_FOLDER=/imagegeneration/installers"
    ]
    execute_command = "sudo sh -c '{{ .Vars }} pwsh -f {{ .Path }}'"
    inline = [
      "cd ${var.runner_images_repo_path}",
      "pwsh -f ./images/ubuntu/scripts/build/Install-PowerShellModules.ps1",
      "pwsh -f ./images/ubuntu/scripts/build/Install-PowerShellAzModules.ps1"
    ]
  }

  # Install essential software packages (minimal set)
  provisioner "shell" {
    environment_vars = [
      "HELPER_SCRIPTS=/imagegeneration/helpers",
      "INSTALLER_SCRIPT_FOLDER=/imagegeneration/installers",
      "DEBIAN_FRONTEND=noninteractive"
    ]
    execute_command = "sudo sh -c '{{ .Vars }} {{ .Path }}'"
    inline = [
      "cd ${var.runner_images_repo_path}",
      "# Core GitHub Actions support",
      "./images/ubuntu/scripts/build/install-actions-cache.sh",
      "./images/ubuntu/scripts/build/install-runner-package.sh",
      "# Essential development tools",
      "./images/ubuntu/scripts/build/install-git.sh",
      "./images/ubuntu/scripts/build/install-github-cli.sh",
      "./images/ubuntu/scripts/build/install-dotnetcore-sdk.sh",
      "# Container tools",
      "./images/ubuntu/scripts/build/install-docker.sh"
    ]
  }

  # Install GitVersion manually (not in standard scripts)
  provisioner "shell" {
    environment_vars = [
      "HELPER_SCRIPTS=/imagegeneration/helpers",
      "DEBIAN_FRONTEND=noninteractive"
    ]
    execute_command = "sudo sh -c '{{ .Vars }} {{ .Path }}'"
    inline = [
      "# Install GitVersion",
      "echo 'Installing GitVersion...'",
      "GITVERSION_VERSION=$(curl -s https://api.github.com/repos/GitTools/GitVersion/releases/latest | grep 'tag_name' | cut -d'\"' -f4)",
      "echo \"Latest GitVersion version: $GITVERSION_VERSION\"",
      "curl -sSL \"https://github.com/GitTools/GitVersion/releases/download/$GITVERSION_VERSION/gitversion-linux-x64-$GITVERSION_VERSION.tar.gz\" | tar -xz -C /usr/local/bin",
      "chmod +x /usr/local/bin/gitversion",
      "# Create symlink for global access",
      "ln -sf /usr/local/bin/gitversion /usr/bin/gitversion",
      "# Verify installation",
      "gitversion --version && echo 'GitVersion installed successfully' || echo 'GitVersion installation failed'"
    ]
  }

  # Install and configure minimal toolsets
  provisioner "shell" {
    environment_vars = [
      "HELPER_SCRIPTS=/imagegeneration/helpers",
      "INSTALLER_SCRIPT_FOLDER=/imagegeneration/installers"
    ]
    execute_command = "sudo sh -c '{{ .Vars }} {{ .Path }}'"
    inline = [
      "cd ${var.runner_images_repo_path}",
      "# Enable Docker Buildx (comes with Docker but ensure it's available)",
      "docker buildx version || echo 'Docker Buildx not found'",
      "# Verify all required tools are installed",
      "docker --version",
      "git --version", 
      "gh --version",
      "dotnet --version",
      "gitversion --version || echo 'GitVersion may need manual verification'"
    ]
  }

  # Reboot and cleanup
  provisioner "shell" {
    execute_command   = "sudo sh -c '{{ .Vars }} {{ .Path }}'"
    expect_disconnect = true
    inline            = ["echo 'Reboot VM'", "sudo reboot"]
  }

  provisioner "shell" {
    execute_command     = "sudo sh -c '{{ .Vars }} {{ .Path }}'"
    pause_before        = "1m0s"
    inline              = [
      "cd ${var.runner_images_repo_path}",
      "./images/ubuntu/scripts/build/cleanup.sh"
    ]
    start_retry_timeout = "10m"
  }

  # Generate minimal software report and run basic tests
  provisioner "shell" {
    environment_vars = [
      "IMAGE_VERSION=24.04",
      "INSTALLER_SCRIPT_FOLDER=/imagegeneration/installers"
    ]
    inline = [
      "# Create basic software report",
      "echo '# YDT GitHub Runner - Ubuntu 24.04 Software Report' > /imagegeneration/software-report.md",
      "echo '' >> /imagegeneration/software-report.md",
      "echo '## Installed Software' >> /imagegeneration/software-report.md",
      "echo '' >> /imagegeneration/software-report.md",
      "echo '### Container Tools' >> /imagegeneration/software-report.md",
      "echo '- Docker: '$(docker --version) >> /imagegeneration/software-report.md",
      "echo '- Docker Buildx: '$(docker buildx version) >> /imagegeneration/software-report.md",
      "echo '' >> /imagegeneration/software-report.md",
      "echo '### Development Tools' >> /imagegeneration/software-report.md", 
      "echo '- Git: '$(git --version) >> /imagegeneration/software-report.md",
      "echo '- GitHub CLI: '$(gh --version | head -1) >> /imagegeneration/software-report.md",
      "echo '- .NET SDK: '$(dotnet --version) >> /imagegeneration/software-report.md",
      "echo '- GitVersion: '$(gitversion --version || echo 'Not properly installed') >> /imagegeneration/software-report.md",
      "echo '' >> /imagegeneration/software-report.md",
      "echo 'Build completed: '$(date) >> /imagegeneration/software-report.md"
    ]
  }

  # Configure system
  provisioner "shell" {
    environment_vars = [
      "HELPER_SCRIPT_FOLDER=/imagegeneration/helpers",
      "INSTALLER_SCRIPT_FOLDER=/imagegeneration/installers",
      "IMAGE_FOLDER=/imagegeneration"
    ]
    execute_command = "sudo sh -c '{{ .Vars }} {{ .Path }}'"
    inline = [
      "cd ${var.runner_images_repo_path}",
      "./images/ubuntu/scripts/build/configure-system.sh"
    ]
  }

  # Final validation and cleanup
  provisioner "shell" {
    environment_vars = [
      "HELPER_SCRIPTS=/imagegeneration/helpers"
    ]
    execute_command = "sudo sh -c '{{ .Vars }} {{ .Path }}'"
    inline = [
      "cd ${var.runner_images_repo_path}",
      "./images/ubuntu/scripts/build/post-build-validation.sh"
    ]
  }

  # Final cleanup
  provisioner "shell" {
    execute_command = "sudo sh -c '{{ .Vars }} {{ .Path }}'"
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
