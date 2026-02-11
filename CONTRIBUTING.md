# Contributing to VPC-CNI to Cilium Migration

Thank you for your interest in contributing! This document provides guidelines for contributing to this repository.

## Table of Contents

1. [Code of Conduct](#code-of-conduct)
2. [Getting Started](#getting-started)
3. [Development Workflow](#development-workflow)
4. [Pull Request Process](#pull-request-process)
5. [Coding Standards](#coding-standards)
6. [Documentation](#documentation)
7. [Testing](#testing)

---

## Code of Conduct

This project follows the [CNCF Code of Conduct](https://github.com/cncf/foundation/blob/master/code-of-conduct.md). By participating, you are expected to uphold this code.

---

## Getting Started

### Prerequisites

- AWS Account with EKS permissions
- Terraform >= 1.5
- kubectl >= 1.35
- Helm >= 3.12
- AWS CLI v2
- Git

### Fork and Clone

```bash
# Fork the repository on GitHub

# Clone your fork
git clone https://github.com/your-username/vpc-cni-migration.git
cd vpc-cni-migration

# Add upstream remote
git remote add upstream https://github.com/original-org/vpc-cni-migration.git
```

### Set Up Development Environment

```bash
# Install pre-commit hooks (optional but recommended)
pip install pre-commit
pre-commit install

# Verify Terraform
terraform version

# Verify kubectl
kubectl version --client

# Verify Helm
helm version
```

---

## Development Workflow

### Branching Strategy

We follow a simplified Git Flow:

- `main` - stable, production-ready code
- `develop` - integration branch for features
- `feature/*` - new features
- `fix/*` - bug fixes
- `docs/*` - documentation updates

### Creating a Feature Branch

```bash
# Update your local repository
git checkout main
git pull upstream main

# Create feature branch
git checkout -b feature/your-feature-name

# Make your changes
# ...

# Commit with conventional commits format
git commit -m "feat: add multi-region support"

# Push to your fork
git push origin feature/your-feature-name
```

### Conventional Commits

We use [Conventional Commits](https://www.conventionalcommits.org/) format:

```
<type>(<scope>): <description>

[optional body]

[optional footer]
```

**Types:**
- `feat` - New feature
- `fix` - Bug fix
- `docs` - Documentation changes
- `refactor` - Code refactoring
- `test` - Adding tests
- `chore` - Maintenance tasks
- `ci` - CI/CD changes

**Examples:**
```bash
git commit -m "feat(egress): add multi-gateway load balancing"
git commit -m "fix(migration): resolve CoreDNS PDB deadlock"
git commit -m "docs(architecture): add HA design diagrams"
git commit -m "refactor(terraform): modularize node group configuration"
```

---

## Pull Request Process

### Before Submitting

1. **Test your changes**
   ```bash
   # Run Terraform validation
   cd terraform/
   terraform fmt -check
   terraform validate

   # Test on actual cluster
   terraform plan
   ```

2. **Update documentation**
   - Update README.md if adding features
   - Update relevant docs in docs/
   - Add/update examples if applicable

3. **Run linters**
   ```bash
   # Terraform
   terraform fmt

   # Shell scripts
   shellcheck scripts/*.sh
   ```

### Submitting PR

1. **Create Pull Request**
   - Go to GitHub and create PR from your fork
   - Target `develop` branch (not `main`)
   - Use clear, descriptive title
   - Fill out PR template

2. **PR Title Format**
   ```
   <type>(<scope>): <description>

   Examples:
   feat(egress): add support for multiple egress policies
   fix(migration): handle node drain timeout gracefully
   docs(quickstart): add troubleshooting section
   ```

3. **PR Description Template**
   ```markdown
   ## Description
   Brief description of changes

   ## Motivation and Context
   Why is this change needed? What problem does it solve?

   ## Changes Made
   - Change 1
   - Change 2
   - Change 3

   ## Testing
   How was this tested?
   - [ ] Terraform plan successful
   - [ ] Tested on test cluster
   - [ ] Documentation updated

   ## Checklist
   - [ ] Code follows project style
   - [ ] Tests added/updated
   - [ ] Documentation updated
   - [ ] Conventional commit format used

   ## Related Issues
   Closes #123
   Related to #456
   ```

4. **Wait for Review**
   - Maintainers will review your PR
   - Address feedback and make requested changes
   - Keep PR updated with latest `develop` branch

5. **Merging**
   - Once approved, maintainers will merge
   - Your commits will be squashed into single commit
   - Delete your feature branch after merge

---

## Coding Standards

### Terraform

**Style:**
```hcl
# Use terraform fmt
terraform fmt

# Naming conventions
resource "aws_eks_cluster" "this" {  # Use "this" for primary resource
  name = var.cluster_name            # Use variables for values
  # ...
}

# Variable names: snake_case
variable "cluster_name" {
  type        = string
  description = "EKS cluster name"
}

# Output names: snake_case
output "cluster_endpoint" {
  value = aws_eks_cluster.this.endpoint
}
```

**Best Practices:**
- Always include descriptions for variables and outputs
- Use consistent naming across modules
- Add validation rules for variables when possible
- Include default values where appropriate
- Comment complex logic

### Bash Scripts

**Style:**
```bash
#!/bin/bash
set -euo pipefail  # Exit on error, undefined var, pipe failure

# Function names: snake_case
function migrate_node() {
  local node_name=$1

  echo "Migrating node: $node_name"
  # ...
}

# Use double quotes for variables
kubectl get pods --context "$CLUSTER_NAME"

# Check command existence
if ! command -v kubectl &> /dev/null; then
  echo "kubectl not found"
  exit 1
fi
```

**Best Practices:**
- Use `set -euo pipefail` at script start
- Quote all variables
- Use local variables in functions
- Check prerequisites before execution
- Provide helpful error messages

### Kubernetes Manifests

**Style:**
```yaml
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: example-app
  namespace: default
  labels:
    app: example-app
    version: v1.0.0
spec:
  replicas: 3
  selector:
    matchLabels:
      app: example-app
  template:
    metadata:
      labels:
        app: example-app
        version: v1.0.0
    spec:
      containers:
      - name: app
        image: nginx:alpine
        resources:
          requests:
            memory: "64Mi"
            cpu: "100m"
          limits:
            memory: "128Mi"
            cpu: "200m"
```

**Best Practices:**
- Always specify resource requests and limits
- Use meaningful labels
- Include namespace explicitly
- Use specific image tags (not `latest`)
- Add health checks when appropriate

---

## Documentation

### Documentation Structure

```
docs/
├── QUICKSTART.md         # Getting started guide
├── MIGRATION-REPORT.md   # Comprehensive migration docs
├── EGRESS-GATEWAY-SETUP.md # Egress gateway guide
├── ARCHITECTURE.md       # Architecture overview
├── TROUBLESHOOTING.md    # Troubleshooting guide
└── [NEW].md              # Your new doc here
```

### Writing Documentation

**Format:**
- Use Markdown
- Follow existing structure
- Include code examples
- Add diagrams where helpful
- Link to related docs

**Style Guide:**
- Use headings hierarchy (# → ## → ###)
- Keep paragraphs short (3-4 sentences)
- Use bullet points for lists
- Use code blocks with language tags
- Include table of contents for long docs

**Example:**
```markdown
# Feature Name

Brief description of the feature.

## Overview

Detailed explanation of what it does and why.

## Prerequisites

- Requirement 1
- Requirement 2

## Configuration

\`\`\`yaml
example: configuration
\`\`\`

## Usage

\`\`\`bash
example-command
\`\`\`

## Troubleshooting

### Common Issue 1

**Symptoms:** ...
**Solution:** ...
```

---

## Testing

### Terraform Testing

```bash
# Format check
terraform fmt -check -recursive

# Validation
terraform validate

# Plan (dry-run)
terraform plan -out=test.tfplan

# Clean up
rm test.tfplan
```

### Integration Testing

```bash
# Deploy to test cluster
cd terraform/
terraform apply -auto-approve

# Run tests
cd ../
./scripts/test-connectivity.sh

# Clean up
cd terraform/
terraform destroy -auto-approve
```

### Manual Testing Checklist

- [ ] VPC-CNI baseline deployment works
- [ ] Migration to Cilium completes successfully
- [ ] Egress gateway routing works
- [ ] All connectivity tests pass
- [ ] Documentation is accurate and complete
- [ ] Examples work as documented

---

## Review Process

### What Reviewers Look For

1. **Code Quality**
   - Follows coding standards
   - Well-commented
   - No unnecessary complexity

2. **Testing**
   - Changes are tested
   - Tests are included if applicable
   - Manual testing documented

3. **Documentation**
   - Changes are documented
   - Examples are clear
   - README updated if needed

4. **Compatibility**
   - Backward compatible when possible
   - Breaking changes clearly noted
   - Migration path provided

### Addressing Feedback

- Respond to all comments
- Make requested changes promptly
- Ask questions if unclear
- Keep conversation constructive

---

## Release Process

Releases are managed by maintainers:

1. Version bump (semver: MAJOR.MINOR.PATCH)
2. Update CHANGELOG.md
3. Create release tag
4. Publish release notes

---

## Getting Help

### Channels

- **Issues**: Report bugs or request features
- **Discussions**: Ask questions, share ideas
- **Pull Requests**: Contribute code or docs

### Response Time

- Issues: Within 3 business days
- Pull Requests: Within 5 business days
- Critical bugs: Within 1 business day

---

## Recognition

Contributors will be:
- Listed in CONTRIBUTORS.md
- Mentioned in release notes
- Given credit in commit history

Thank you for contributing! 🎉
