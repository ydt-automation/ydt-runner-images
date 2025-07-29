#!/bin/bash

# Default values
AWS_PROFILE="ydtdev"
AWS_REGION="ap-southeast-1"

# Parse command line arguments
while [[ $# -gt 0 ]]; do
    key="$1"
    case $key in
        --profile)
            AWS_PROFILE="$2"
            shift
            shift
            ;;
        --region)
            AWS_REGION="$2"
            shift
            shift
            ;;
        *)
            echo "Unknown option: $1"
            exit 1
            ;;
    esac
done

echo "Using AWS Profile: $AWS_PROFILE"
echo "Using AWS Region: $AWS_REGION"

# Ensure AWS SSO session is active
if ! aws sts get-caller-identity --profile $AWS_PROFILE; then
    echo "Please login to AWS SSO first using: aws sso login --profile $AWS_PROFILE"
    exit 1
fi

echo -e "\n=== AWS Account Info ==="
aws sts get-caller-identity --profile $AWS_PROFILE

echo -e "\n=== IAM Roles with SSM Access ==="
# List roles that have SSM policies attached
echo "Checking for roles with SSM managed policies..."
aws iam list-roles \
    --profile $AWS_PROFILE \
    --query 'Roles[?contains(to_string(AssumeRolePolicyDocument), `ec2.amazonaws.com`) && contains(RoleName, `SSM`)].[RoleName,Arn]' \
    --output table

# Also check for instance profiles as they're needed for EC2 to use the role
echo -e "\nChecking for instance profiles..."
aws iam list-instance-profiles \
    --profile $AWS_PROFILE \
    --query 'InstanceProfiles[?contains(InstanceProfileName, `SSM`)].[InstanceProfileName,Arn]' \
    --output table

echo -e "\n=== VPCs ==="
aws ec2 describe-vpcs \
    --profile $AWS_PROFILE \
    --region $AWS_REGION \
    --query 'Vpcs[*].[VpcId,Tags[?Key==`Name`].Value|[0],CidrBlock]' \
    --output table

echo -e "\n=== Security Groups ==="
aws ec2 describe-security-groups \
    --profile $AWS_PROFILE \
    --region $AWS_REGION \
    --query 'SecurityGroups[*].[GroupName,GroupId,VpcId]' \
    --output table

echo -e "\n=== Subnets ==="
aws ec2 describe-subnets \
    --profile $AWS_PROFILE \
    --region $AWS_REGION \
    --query 'Subnets[*].[SubnetId,VpcId,AvailabilityZone,CidrBlock,Tags[?Key==`Name`].Value|[0]]' \
    --output table

# Function to create SSM role and instance profile if needed
check_and_create_ssm_role() {
    ROLE_NAME="GitHubActionsRunnerSSMRole"
    PROFILE_NAME="GitHubActionsRunnerSSMProfile"

    # Check if role exists
    if ! aws iam get-role --profile $AWS_PROFILE --role-name $ROLE_NAME &>/dev/null; then
        echo "Creating IAM role for SSM access..."
        
        # Create trust policy for EC2
        echo '{
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
        }' > trust-policy.json

        # Create role
        aws iam create-role \
            --profile $AWS_PROFILE \
            --role-name $ROLE_NAME \
            --assume-role-policy-document file://trust-policy.json

        # Create policy for runner permissions
        echo '{
            "Version": "2012-10-17",
            "Statement": [
                {
                    "Effect": "Allow",
                    "Action": [
                        "ssm:UpdateInstanceInformation",
                        "ssmmessages:CreateControlChannel",
                        "ssmmessages:CreateDataChannel",
                        "ssmmessages:OpenControlChannel",
                        "ssmmessages:OpenDataChannel",
                        "ec2messages:AcknowledgeMessage",
                        "ec2messages:DeleteMessage",
                        "ec2messages:FailMessage",
                        "ec2messages:GetEndpoint",
                        "ec2messages:GetMessages",
                        "ec2messages:SendReply",
                        "cloudwatch:PutMetricData",
                        "ec2:DescribeInstances",
                        "ds:CreateComputer",
                        "ds:DescribeDirectories",
                        "logs:CreateLogGroup",
                        "logs:CreateLogStream",
                        "logs:DescribeLogGroups",
                        "logs:DescribeLogStreams",
                        "logs:PutLogEvents"
                    ],
                    "Resource": "*"
                }
            ]
        }' > runner-policy.json

        # Create the policy
        aws iam create-policy \
            --profile $AWS_PROFILE \
            --policy-name "GitHubActionsRunnerPolicy" \
            --policy-document file://runner-policy.json

        # Get account ID for policy ARN
        ACCOUNT_ID=$(aws sts get-caller-identity --profile $AWS_PROFILE --query Account --output text)

        # Attach policies
        aws iam attach-role-policy \
            --profile $AWS_PROFILE \
            --role-name $ROLE_NAME \
            --policy-arn arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore

        aws iam attach-role-policy \
            --profile $AWS_PROFILE \
            --role-name $ROLE_NAME \
            --policy-arn arn:aws:iam::$ACCOUNT_ID:policy/GitHubActionsRunnerPolicy

        rm trust-policy.json
        echo "✅ Created role $ROLE_NAME"
    else
        echo "✅ Role $ROLE_NAME already exists"
    fi

    # Check if instance profile exists
    if ! aws iam get-instance-profile --profile $AWS_PROFILE --instance-profile-name $PROFILE_NAME &>/dev/null; then
        echo "Creating instance profile..."
        aws iam create-instance-profile \
            --profile $AWS_PROFILE \
            --instance-profile-name $PROFILE_NAME

        # Add role to profile
        aws iam add-role-to-instance-profile \
            --profile $AWS_PROFILE \
            --instance-profile-name $PROFILE_NAME \
            --role-name $ROLE_NAME

        echo "✅ Created instance profile $PROFILE_NAME"
    else
        echo "✅ Instance profile $PROFILE_NAME already exists"
    fi

    # Store the instance profile name for later use
    SSM_INSTANCE_PROFILE=$PROFILE_NAME
}

echo -e "\n=== Checking SSM Role Setup ==="
check_and_create_ssm_role

echo -e "\n=== Creating Resource Summary ==="
echo "Copy these values to your GitHub repository secrets:"
echo "----------------------------------------"

# Key Pair selection
echo -e "\nKey Pair Selection:"
echo "Enter the Key Pair name to use"
echo "(If you just created a new key pair, use that name)"
read -p "Key Pair name: " KEY_NAME

# Security Group selection
echo -e "\nSecurity Group Selection:"
echo "Recommended: Use the security group with 'github-actions-runner' in the name"
echo "From your list, that would be: sg-09469a23127c342aa"
read -p "Security Group ID: " SG_ID

# Subnet selection
echo -e "\nSubnet Selection:"
echo "Choose a subnet, preferably in AZ 'a' for better availability"
echo "Recommended: subnet-0eb39f752548eb6d0 (ap-southeast-1a)"
read -p "Subnet ID: " SUBNET_ID

echo -e "\nAdd these secrets to GitHub:"
echo "----------------------------------------"
echo "EC2_SECURITY_GROUP_ID: $SG_ID"
echo "EC2_SUBNET_ID: $SUBNET_ID"
echo "SSM_INSTANCE_PROFILE: $SSM_INSTANCE_PROFILE"
echo "----------------------------------------"

# Validate the resources
echo -e "\nValidating resources..."

if aws ec2 describe-key-pairs \
    --profile $AWS_PROFILE \
    --region $AWS_REGION \
    --key-names "$KEY_NAME" &>/dev/null; then
    echo "✅ Key pair '$KEY_NAME' exists"
else
    echo "❌ Key pair '$KEY_NAME' not found"
fi

if aws ec2 describe-security-groups \
    --profile $AWS_PROFILE \
    --region $AWS_REGION \
    --group-ids "$SG_ID" &>/dev/null; then
    echo "✅ Security group '$SG_ID' exists"
else
    echo "❌ Security group '$SG_ID' not found"
fi

if aws ec2 describe-subnets \
    --profile $AWS_PROFILE \
    --region $AWS_REGION \
    --subnet-ids "$SUBNET_ID" &>/dev/null; then
    echo "✅ Subnet '$SUBNET_ID' exists"
else
    echo "❌ Subnet '$SUBNET_ID' not found"
fi
