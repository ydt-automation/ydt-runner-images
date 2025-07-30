# AWS Setup for GitHub Actions AMI Building

This script sets up all required AWS resources for building AMIs with GitHub Actions.

## Quick Start

```bash
# Run the setup script
./scripts/setup-aws.sh --profile your-aws-profile --region your-region

# Add the output secrets to your GitHub repository
# Then test the workflow
```

## What it creates

1. **GitHub OIDC Provider** - Allows GitHub Actions to authenticate with AWS
2. **GitHubActionsWorkflowRole** - IAM role for the GitHub Actions workflow
3. **GitHubActionsRunnerSSMRole** - IAM role for EC2 test instances with SSM access
4. **Security Group** - Basic security group for runner instances
5. **Required GitHub Secrets** - Shows you exactly what to add

## GitHub Secrets Required

After running the setup script, add these 3 secrets to your repository:

- `AWS_ROLE_ARN` - ARN of the workflow role
- `EC2_SECURITY_GROUP_ID` - Security group for test instances  
- `EC2_SUBNET_ID` - Subnet for test instances

## Testing

Trigger the AMI build workflow manually to test the setup:
- Go to Actions tab in GitHub
- Run "Build AMI" workflow
- Monitor the build process
