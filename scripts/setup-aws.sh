#!/bin/bash

# AWS GitHub Actions Setup Script
# This script sets up all required AWS resources for GitHub Actions AMI building

set -e

# Default values
AWS_PROFILE="${AWS_PROFILE:-default}"
AWS_REGION="${AWS_REGION:-us-east-1}"

# Parse command line arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        --profile) AWS_PROFILE="$2"; shift 2 ;;
        --region) AWS_REGION="$2"; shift 2 ;;
        --help) 
            echo "Usage: $0 [--profile PROFILE] [--region REGION]"
            echo "Sets up AWS resources for GitHub Actions AMI building"
            exit 0 ;;
        *) echo "Unknown option: $1"; exit 1 ;;
    esac
done

echo "Setting up AWS resources for GitHub Actions..."
echo "Profile: $AWS_PROFILE | Region: $AWS_REGION"

# Get AWS account info
ACCOUNT_ID=$(aws sts get-caller-identity --profile $AWS_PROFILE --query Account --output text)
REPO_OWNER=$(git config --get remote.origin.url | sed 's/.*github\.com[:/]\([^/]*\).*/\1/')
REPO_NAME=$(basename $(git config --get remote.origin.url) .git)

echo "Account ID: $ACCOUNT_ID"
echo "Repository: $REPO_OWNER/$REPO_NAME"

# Function to create GitHub OIDC provider
setup_oidc_provider() {
    echo -e "\n=== GitHub OIDC Provider ==="
    local provider_arn="arn:aws:iam::$ACCOUNT_ID:oidc-provider/token.actions.githubusercontent.com"
    
    if aws iam get-open-id-connect-provider --profile $AWS_PROFILE --open-id-connect-provider-arn "$provider_arn" &>/dev/null; then
        echo "✅ GitHub OIDC provider exists"
    else
        echo "Creating GitHub OIDC provider..."
        aws iam create-open-id-connect-provider \
            --profile $AWS_PROFILE \
            --url "https://token.actions.githubusercontent.com" \
            --client-id-list "sts.amazonaws.com" \
            --thumbprint-list "6938fd4d98bab03faadb97b34396831e3780aea1"
        echo "✅ Created GitHub OIDC provider"
    fi
}

# Function to create GitHub Actions workflow role
setup_workflow_role() {
    echo -e "\n=== GitHub Actions Workflow Role ==="
    local role_name="GitHubActionsWorkflowRole"
    local policy_name="GitHubActionsWorkflowPolicy"
    
    # Create trust policy
    cat > trust-policy.json << EOF
{
    "Version": "2012-10-17",
    "Statement": [
        {
            "Effect": "Allow",
            "Principal": {
                "Federated": "arn:aws:iam::$ACCOUNT_ID:oidc-provider/token.actions.githubusercontent.com"
            },
            "Action": "sts:AssumeRoleWithWebIdentity",
            "Condition": {
                "StringLike": {
                    "token.actions.githubusercontent.com:sub": "repo:$REPO_OWNER/$REPO_NAME:*"
                },
                "StringEquals": {
                    "token.actions.githubusercontent.com:aud": "sts.amazonaws.com"
                }
            }
        }
    ]
}
EOF

    # Create permissions policy
    cat > workflow-policy.json << EOF
{
    "Version": "2012-10-17",
    "Statement": [
        {
            "Effect": "Allow",
            "Action": [
                "ec2:RunInstances",
                "ec2:TerminateInstances",
                "ec2:CreateTags",
                "ec2:DescribeInstances",
                "ec2:DescribeImages",
                "ec2:DescribeVolumes",
                "ec2:CreateImage",
                "ec2:DescribeSecurityGroups",
                "ec2:DescribeSubnets",
                "ec2:DescribeVpcs",
                "ec2:DescribeRegions",
                "ec2:DescribeAvailabilityZones",
                "ec2:DescribeKeyPairs",
                "ec2:CreateKeyPair",
                "ec2:DeleteKeyPair",
                "ec2:ModifyImageAttribute",
                "ec2:DescribeInstanceAttribute",
                "ec2:ModifyInstanceAttribute",
                "ec2:DescribeInstanceTypeOfferings",
                "ec2:CreateSecurityGroup",
                "ec2:DeleteSecurityGroup",
                "ec2:AuthorizeSecurityGroupIngress",
                "ec2:AuthorizeSecurityGroupEgress",
                "ec2:RevokeSecurityGroupIngress",
                "ec2:RevokeSecurityGroupEgress",
                "ec2:CreateLaunchTemplate",
                "ec2:DeleteLaunchTemplate",
                "ec2:DescribeLaunchTemplates",
                "ec2:CreateFleet",
                "ec2:DescribeFleets",
                "ec2:DescribeSpotFleetInstances",
                "ec2:DescribeSpotFleetRequests",
                "ec2:RequestSpotFleet",
                "ec2:CancelSpotFleetRequests",
                "ec2:DescribeSpotInstanceRequests",
                "ec2:RequestSpotInstances",
                "ec2:CancelSpotInstanceRequests",
                "iam:PassRole",
                "ec2:DeregisterImage",
                "ec2:CopyImage"
            ],
            "Resource": "*"
        },
        {
            "Effect": "Allow",
            "Action": "iam:PassRole",
            "Resource": "arn:aws:iam::$ACCOUNT_ID:role/GitHubActionsRunnerSSMRole",
            "Condition": {
                "StringEquals": {
                    "iam:PassedToService": "ec2.amazonaws.com"
                }
            }
        }
    ]
}
EOF

    # Create role
    if aws iam get-role --profile $AWS_PROFILE --role-name $role_name &>/dev/null; then
        echo "✅ Role $role_name exists"
    else
        aws iam create-role \
            --profile $AWS_PROFILE \
            --role-name $role_name \
            --assume-role-policy-document file://trust-policy.json \
            --description "GitHub Actions workflow role for AMI building"
        echo "✅ Created role $role_name"
    fi

    # Create and attach policy
    if aws iam get-policy --profile $AWS_PROFILE --policy-arn "arn:aws:iam::$ACCOUNT_ID:policy/$policy_name" &>/dev/null; then
        echo "✅ Policy $policy_name exists"
    else
        aws iam create-policy \
            --profile $AWS_PROFILE \
            --policy-name $policy_name \
            --policy-document file://workflow-policy.json \
            --description "Permissions for GitHub Actions AMI building"
        echo "✅ Created policy $policy_name"
    fi

    aws iam attach-role-policy \
        --profile $AWS_PROFILE \
        --role-name $role_name \
        --policy-arn "arn:aws:iam::$ACCOUNT_ID:policy/$policy_name"

    rm trust-policy.json workflow-policy.json
}

# Function to create SSM role for instances
setup_ssm_role() {
    echo -e "\n=== SSM Instance Role ==="
    local role_name="GitHubActionsRunnerSSMRole"
    local profile_name="GitHubActionsRunnerSSMProfile"
    
    # Create trust policy for EC2
    cat > ssm-trust-policy.json << EOF
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
EOF

    # Create role
    if aws iam get-role --profile $AWS_PROFILE --role-name $role_name &>/dev/null; then
        echo "✅ Role $role_name exists"
    else
        aws iam create-role \
            --profile $AWS_PROFILE \
            --role-name $role_name \
            --assume-role-policy-document file://ssm-trust-policy.json \
            --description "SSM role for GitHub Actions runner instances"
        
        aws iam attach-role-policy \
            --profile $AWS_PROFILE \
            --role-name $role_name \
            --policy-arn arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore
        echo "✅ Created role $role_name"
    fi

    # Create instance profile
    if aws iam get-instance-profile --profile $AWS_PROFILE --instance-profile-name $profile_name &>/dev/null; then
        echo "✅ Instance profile $profile_name exists"
    else
        aws iam create-instance-profile \
            --profile $AWS_PROFILE \
            --instance-profile-name $profile_name

        aws iam add-role-to-instance-profile \
            --profile $AWS_PROFILE \
            --instance-profile-name $profile_name \
            --role-name $role_name
        echo "✅ Created instance profile $profile_name"
    fi

    rm ssm-trust-policy.json
}

# Function to get networking resources
get_networking_resources() {
    echo -e "\n=== Networking Resources ==="
    
    # Get default VPC and subnets
    local vpc_id=$(aws ec2 describe-vpcs --profile $AWS_PROFILE --region $AWS_REGION \
        --query 'Vpcs[?IsDefault==`true`].VpcId' --output text)
    
    if [[ -z "$vpc_id" ]]; then
        echo "❌ No default VPC found. Please ensure you have a default VPC or specify resources manually."
        exit 1
    fi

    local subnet_id=$(aws ec2 describe-subnets --profile $AWS_PROFILE --region $AWS_REGION \
        --filters "Name=vpc-id,Values=$vpc_id" "Name=default-for-az,Values=true" \
        --query 'Subnets[0].SubnetId' --output text)
    
    # Get or create security group
    local sg_id=$(aws ec2 describe-security-groups --profile $AWS_PROFILE --region $AWS_REGION \
        --filters "Name=group-name,Values=github-actions-runner" \
        --query 'SecurityGroups[0].GroupId' --output text 2>/dev/null || echo "None")
    
    if [[ "$sg_id" == "None" ]]; then
        echo "Creating security group..."
        sg_id=$(aws ec2 create-security-group \
            --profile $AWS_PROFILE \
            --region $AWS_REGION \
            --group-name github-actions-runner \
            --description "Security group for GitHub Actions runner instances" \
            --vpc-id $vpc_id \
            --query 'GroupId' --output text)
        echo "✅ Created security group: $sg_id"
    else
        echo "✅ Using existing security group: $sg_id"
    fi

    echo "✅ VPC: $vpc_id"
    echo "✅ Subnet: $subnet_id"
    echo "✅ Security Group: $sg_id"

    # Export for final summary
    SECURITY_GROUP_ID=$sg_id
    SUBNET_ID=$subnet_id
}

# Main execution
setup_oidc_provider
setup_workflow_role
setup_ssm_role
get_networking_resources

# Final summary
echo -e "\n🎉 Setup Complete!"
echo "Add these secrets to your GitHub repository:"
echo "----------------------------------------"
echo "AWS_ROLE_ARN: arn:aws:iam::$ACCOUNT_ID:role/GitHubActionsWorkflowRole"
echo "EC2_SECURITY_GROUP_ID: $SECURITY_GROUP_ID"
echo "EC2_SUBNET_ID: $SUBNET_ID"
echo "----------------------------------------"

echo -e "\nNext steps:"
echo "1. Add the above secrets to GitHub repository settings"
echo "2. Test the AMI build workflow"
echo "3. Monitor CloudWatch logs for any issues"
