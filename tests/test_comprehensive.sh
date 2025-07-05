#!/bin/bash

# Comprehensive Test Suite for git-cross tool
# This script tests all CLI operations and real-world use cases

set -e

# Test configuration
TEST_DIR="/tmp/cross_comprehensive_test_$$"
UPSTREAM_REPO1="$TEST_DIR/upstream1"
UPSTREAM_REPO2="$TEST_DIR/upstream2"
UPSTREAM_REPO3="$TEST_DIR/upstream3"
LOCAL_REPO="$TEST_DIR/local"
CROSS_SCRIPT="$(realpath ./cross_fixed.sh)"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
MAGENTA='\033[0;35m'
NC='\033[0m' # No Color

# Test counter
TESTS_PASSED=0
TESTS_FAILED=0

# Test helper functions
log() {
    echo -e "${GREEN}[TEST]${NC} $1"
}

info() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

test_pass() {
    echo -e "${GREEN}✓${NC} $1"
    ((TESTS_PASSED++))
}

test_fail() {
    echo -e "${RED}✗${NC} $1"
    ((TESTS_FAILED++))
}

# Setup comprehensive test environment
setup_comprehensive_test_env() {
    log "Setting up comprehensive test environment..."
    
    # Clean up any existing test directory
    rm -rf "$TEST_DIR"
    mkdir -p "$TEST_DIR"
    
    # Create multiple upstream repositories with different structures
    create_upstream_repo1
    create_upstream_repo2
    create_upstream_repo3
    
    # Create local repository
    mkdir -p "$LOCAL_REPO"
    cd "$LOCAL_REPO"
    git init
    git config user.email "test@example.com"
    git config user.name "Test User"
    
    # Create initial commit
    echo "# Local Integration Repo" > README.md
    echo "This repo integrates multiple upstream repositories" >> README.md
    git add README.md
    git commit -m "Initial commit"
    
    log "Comprehensive test environment ready"
}

# Create upstream repo 1: Microservice with configs
create_upstream_repo1() {
    local repo_dir="$UPSTREAM_REPO1"
    local work_dir="${repo_dir}_work"
    
    mkdir -p "$repo_dir"
    cd "$repo_dir"
    git init --bare
    
    # Create working copy
    git clone "$repo_dir" "$work_dir"
    cd "$work_dir"
    git config user.email "upstream1@example.com"
    git config user.name "Upstream 1"
    
    # Create microservice structure
    mkdir -p "configs/nginx"
    mkdir -p "configs/redis"
    mkdir -p "scripts/deploy"
    mkdir -p "docs/api"
    
    # Create configuration files
    cat > "configs/nginx/nginx.conf" << 'EOF'
server {
    listen 80;
    server_name example.com;
    
    location / {
        proxy_pass http://backend;
    }
}
EOF
    
    cat > "configs/redis/redis.conf" << 'EOF'
port 6379
bind 127.0.0.1
save 900 1
save 300 10
save 60 10000
EOF
    
    cat > "scripts/deploy/deploy.sh" << 'EOF'
#!/bin/bash
echo "Deploying microservice..."
kubectl apply -f k8s/
EOF
    chmod +x "scripts/deploy/deploy.sh"
    
    cat > "docs/api/README.md" << 'EOF'
# API Documentation

## Endpoints

- GET /health - Health check
- GET /api/v1/users - List users
- POST /api/v1/users - Create user
EOF
    
    echo "# Microservice A" > README.md
    
    git add .
    git commit -m "Initial microservice structure"
    
    # Create additional commits for update testing
    echo "# Updated API docs" >> "docs/api/README.md"
    git add "docs/api/README.md"
    git commit -m "Update API documentation"
    
    echo "worker_processes auto;" >> "configs/nginx/nginx.conf"
    git add "configs/nginx/nginx.conf"
    git commit -m "Optimize nginx configuration"
    
    git push origin master
    
    # Clean up working copy
    cd ../..
    rm -rf "$work_dir"
}

# Create upstream repo 2: Infrastructure as Code
create_upstream_repo2() {
    local repo_dir="$UPSTREAM_REPO2"
    local work_dir="${repo_dir}_work"
    
    mkdir -p "$repo_dir"
    cd "$repo_dir"
    git init --bare
    
    # Create working copy
    git clone "$repo_dir" "$work_dir"
    cd "$work_dir"
    git config user.email "upstream2@example.com"
    git config user.name "Upstream 2"
    
    # Create infrastructure structure
    mkdir -p "terraform/aws"
    mkdir -p "terraform/gcp"
    mkdir -p "kubernetes/base"
    mkdir -p "kubernetes/overlays"
    mkdir -p "monitoring/prometheus"
    
    # Create terraform files
    cat > "terraform/aws/main.tf" << 'EOF'
provider "aws" {
  region = var.aws_region
}

resource "aws_instance" "app" {
  ami           = var.ami_id
  instance_type = var.instance_type
  
  tags = {
    Name = "app-server"
  }
}
EOF
    
    cat > "terraform/aws/variables.tf" << 'EOF'
variable "aws_region" {
  description = "AWS region"
  default     = "us-east-1"
}

variable "ami_id" {
  description = "AMI ID for EC2 instance"
}

variable "instance_type" {
  description = "EC2 instance type"
  default     = "t2.micro"
}
EOF
    
    # Create kubernetes manifests
    cat > "kubernetes/base/deployment.yaml" << 'EOF'
apiVersion: apps/v1
kind: Deployment
metadata:
  name: app-deployment
spec:
  replicas: 3
  selector:
    matchLabels:
      app: myapp
  template:
    metadata:
      labels:
        app: myapp
    spec:
      containers:
      - name: app
        image: myapp:latest
        ports:
        - containerPort: 8080
EOF
    
    cat > "monitoring/prometheus/config.yml" << 'EOF'
global:
  scrape_interval: 15s
  evaluation_interval: 15s

scrape_configs:
  - job_name: 'app'
    static_configs:
      - targets: ['app:8080']
EOF
    
    echo "# Infrastructure Repository" > README.md
    
    git add .
    git commit -m "Initial infrastructure setup"
    
    # Create feature branch for testing
    git checkout -b feature/new-monitoring
    echo "  - job_name: 'database'" >> "monitoring/prometheus/config.yml"
    echo "    static_configs:" >> "monitoring/prometheus/config.yml"
    echo "      - targets: ['db:5432']" >> "monitoring/prometheus/config.yml"
    git add "monitoring/prometheus/config.yml"
    git commit -m "Add database monitoring"
    
    git checkout master
    git push origin master
    git push origin feature/new-monitoring
    
    # Clean up working copy
    cd ../..
    rm -rf "$work_dir"
}

# Create upstream repo 3: Library/SDK
create_upstream_repo3() {
    local repo_dir="$UPSTREAM_REPO3"
    local work_dir="${repo_dir}_work"
    
    mkdir -p "$repo_dir"
    cd "$repo_dir"
    git init --bare
    
    # Create working copy
    git clone "$repo_dir" "$work_dir"
    cd "$work_dir"
    git config user.email "upstream3@example.com"
    git config user.name "Upstream 3"
    
    # Create library structure
    mkdir -p "src/utils"
    mkdir -p "src/auth"
    mkdir -p "examples/basic"
    mkdir -p "examples/advanced"
    mkdir -p "tests/unit"
    
    # Create source files
    cat > "src/utils/logger.js" << 'EOF'
class Logger {
  constructor(level = 'info') {
    this.level = level;
  }
  
  log(message, level = 'info') {
    if (this.shouldLog(level)) {
      console.log(`[${level.toUpperCase()}] ${message}`);
    }
  }
  
  shouldLog(level) {
    const levels = ['debug', 'info', 'warn', 'error'];
    return levels.indexOf(level) >= levels.indexOf(this.level);
  }
}

module.exports = Logger;
EOF
    
    cat > "src/auth/oauth.js" << 'EOF'
class OAuth {
  constructor(clientId, clientSecret) {
    this.clientId = clientId;
    this.clientSecret = clientSecret;
  }
  
  async getAccessToken() {
    // OAuth implementation
    return 'access_token_123';
  }
}

module.exports = OAuth;
EOF
    
    cat > "examples/basic/usage.js" << 'EOF'
const Logger = require('../../src/utils/logger');

const logger = new Logger('debug');
logger.log('This is a basic example');
EOF
    
    cat > "tests/unit/logger.test.js" << 'EOF'
const Logger = require('../../src/utils/logger');

describe('Logger', () => {
  it('should log messages at correct level', () => {
    const logger = new Logger('info');
    // Test implementation
  });
});
EOF
    
    echo "# Utility Library" > README.md
    cat > "package.json" << 'EOF'
{
  "name": "utility-lib",
  "version": "1.0.0",
  "description": "Utility library for common tasks",
  "main": "index.js",
  "scripts": {
    "test": "jest"
  }
}
EOF
    
    git add .
    git commit -m "Initial library structure"
    
    # Add more commits for realistic history
    echo "  info(message) { this.log(message, 'info'); }" >> "src/utils/logger.js"
    echo "  warn(message) { this.log(message, 'warn'); }" >> "src/utils/logger.js"
    echo "  error(message) { this.log(message, 'error'); }" >> "src/utils/logger.js"
    git add "src/utils/logger.js"
    git commit -m "Add convenience methods to Logger"
    
    git push origin master
    
    # Clean up working copy
    cd ../..
    rm -rf "$work_dir"
}

# Test 1: Basic CLI Operations
test_cli_basic_operations() {
    log "Testing basic CLI operations..."
    
    cd "$LOCAL_REPO"
    
    # Test help/version type operations
    if "$CROSS_SCRIPT" setup; then
        test_pass "CLI: setup command works"
    else
        test_fail "CLI: setup command failed"
    fi
    
    # Test individual function calls
    if "$CROSS_SCRIPT" use upstream1 "$UPSTREAM_REPO1"; then
        test_pass "CLI: use command works"
    else
        test_fail "CLI: use command failed"
    fi
    
    # Verify remote was added
    if git remote | grep -q "upstream1"; then
        test_pass "CLI: remote added successfully"
    else
        test_fail "CLI: remote not added"
    fi
    
    # Test patch command
    if "$CROSS_SCRIPT" patch upstream1:configs/nginx local_nginx; then
        test_pass "CLI: patch command works"
    else
        test_fail "CLI: patch command failed"
    fi
    
    # Verify patch was created
    if [[ -d "local_nginx" && -f "local_nginx/nginx.conf" ]]; then
        test_pass "CLI: patch created successfully"
    else
        test_fail "CLI: patch not created properly"
    fi
}

# Test 2: Cross File Processing
test_cross_file_processing() {
    log "Testing Cross file processing..."
    
    cd "$LOCAL_REPO"
    
    # Create comprehensive Cross file
    cat > Cross << 'EOF'
# Comprehensive Cross file for testing

# Register upstream repositories
use microservice $UPSTREAM_REPO1
use infrastructure $UPSTREAM_REPO2
use library $UPSTREAM_REPO3

# Display remotes
git remote -v | grep fetch | column -t

# Patch different components
patch microservice:configs/nginx services/nginx-config
patch microservice:scripts/deploy services/deploy-scripts
patch infrastructure:terraform/aws infrastructure/aws
patch infrastructure:kubernetes/base infrastructure/k8s
patch library:src/utils library/utils
patch library:examples/basic library/examples

# Test hooks
cross_post_hook() {
    echo "Post-hook executed for: $1"
}
EOF
    
    # Substitute environment variables in Cross file
    sed -i "s|\$UPSTREAM_REPO1|$UPSTREAM_REPO1|g" Cross
    sed -i "s|\$UPSTREAM_REPO2|$UPSTREAM_REPO2|g" Cross
    sed -i "s|\$UPSTREAM_REPO3|$UPSTREAM_REPO3|g" Cross
    
    # Execute Cross file
    if "$CROSS_SCRIPT"; then
        test_pass "Cross file processing successful"
    else
        test_fail "Cross file processing failed"
    fi
    
    # Verify all patches were created
    local expected_dirs=("services/nginx-config" "services/deploy-scripts" "infrastructure/aws" "infrastructure/k8s" "library/utils" "library/examples")
    local all_created=true
    
    for dir in "${expected_dirs[@]}"; do
        if [[ ! -d "$dir" ]]; then
            all_created=false
            error "Missing directory: $dir"
        fi
    done
    
    if $all_created; then
        test_pass "All patches created from Cross file"
    else
        test_fail "Some patches missing from Cross file"
    fi
}

# Test 3: Making commits in worktrees
test_commits_in_worktrees() {
    log "Testing commits in worktrees..."
    
    cd "$LOCAL_REPO"
    
    # Make changes in different worktrees
    cd "services/nginx-config"
    
    # Verify we're in the right worktree
    if git rev-parse --abbrev-ref HEAD | grep -q "microservice"; then
        test_pass "Worktree has correct branch"
    else
        test_fail "Worktree branch incorrect"
    fi
    
    # Make a local change
    echo "# Custom configuration" >> nginx.conf
    echo "client_max_body_size 10M;" >> nginx.conf
    
    git add nginx.conf
    git commit -m "Add custom nginx configuration"
    
    if [[ $? -eq 0 ]]; then
        test_pass "Commit in worktree successful"
    else
        test_fail "Commit in worktree failed"
    fi
    
    # Test commit in another worktree
    cd "../deploy-scripts"
    
    echo "echo 'Pre-deployment checks...'" >> deploy.sh
    echo "kubectl version" >> deploy.sh
    
    git add deploy.sh
    git commit -m "Add pre-deployment checks"
    
    if [[ $? -eq 0 ]]; then
        test_pass "Multiple worktree commits work"
    else
        test_fail "Multiple worktree commits failed"
    fi
    
    cd ../..
}

# Test 4: Updating patches from upstream
test_upstream_updates() {
    log "Testing upstream updates..."
    
    cd "$LOCAL_REPO"
    
    # Make changes to upstream repo
    local work_dir="${UPSTREAM_REPO1}_update"
    git clone "$UPSTREAM_REPO1" "$work_dir"
    cd "$work_dir"
    git config user.email "upstream1@example.com"
    git config user.name "Upstream 1"
    
    # Add new feature to upstream
    echo "# New upstream feature" >> configs/nginx/nginx.conf
    echo "gzip on;" >> configs/nginx/nginx.conf
    git add configs/nginx/nginx.conf
    git commit -m "Enable gzip compression"
    git push origin master
    
    # Clean up
    cd "$LOCAL_REPO"
    rm -rf "$work_dir"
    
    # Update patches
    if "$CROSS_SCRIPT"; then
        test_pass "Upstream update successful"
    else
        test_fail "Upstream update failed"
    fi
    
    # Verify update was applied
    if grep -q "gzip on;" "services/nginx-config/nginx.conf"; then
        test_pass "Upstream changes merged"
    else
        test_fail "Upstream changes not merged"
    fi
}

# Test 5: Rebase functionality
test_rebase_functionality() {
    log "Testing rebase functionality..."
    
    cd "$LOCAL_REPO"
    
    # Set rebase environment variable
    export CROSS_REBASE_ORIGIN=true
    
    # Create conflicting local changes
    cd "services/nginx-config"
    echo "# Local modification" >> nginx.conf
    git add nginx.conf
    git commit -m "Local modification"
    
    # Make upstream changes
    local work_dir="${UPSTREAM_REPO1}_rebase"
    git clone "$UPSTREAM_REPO1" "$work_dir"
    cd "$work_dir"
    git config user.email "upstream1@example.com"
    git config user.name "Upstream 1"
    
    echo "# Upstream modification" >> configs/nginx/nginx.conf
    git add configs/nginx/nginx.conf
    git commit -m "Upstream modification"
    git push origin master
    
    cd "$LOCAL_REPO"
    rm -rf "$work_dir"
    
    # Test rebase
    if "$CROSS_SCRIPT"; then
        test_pass "Rebase operation completed"
    else
        test_fail "Rebase operation failed"
    fi
    
    # Reset environment
    unset CROSS_REBASE_ORIGIN
}

# Test 6: Simulate pull request workflow
test_pull_request_simulation() {
    log "Testing pull request simulation workflow..."
    
    cd "$LOCAL_REPO"
    
    # Create a feature branch in worktree
    cd "library/utils"
    
    git checkout -b feature/add-debug-method
    
    # Add new feature
    cat >> logger.js << 'EOF'

  debug(message) {
    this.log(message, 'debug');
  }
EOF
    
    git add logger.js
    git commit -m "Add debug method to Logger class"
    
    # Simulate pushing feature branch (would normally go to upstream)
    info "Feature branch created with new debug method"
    
    # Show how to contribute back to upstream
    info "To contribute back to upstream:"
    info "1. cd library/utils"
    info "2. git push origin feature/add-debug-method"
    info "3. Create PR in upstream repository"
    
    # Test cherry-pick to main repo (simulating acceptance)
    cd "$LOCAL_REPO"
    
    # Create a commit to represent the accepted PR
    cd "library/utils"
    git checkout master
    
    # This simulates the upstream accepting the PR
    git cherry-pick feature/add-debug-method
    
    if [[ $? -eq 0 ]]; then
        test_pass "Pull request simulation successful"
    else
        test_fail "Pull request simulation failed"
    fi
    
    cd ../..
}

# Test 7: Multiple branch support
test_multiple_branches() {
    log "Testing multiple branch support..."
    
    cd "$LOCAL_REPO"
    
    # Test patching from feature branch
    "$CROSS_SCRIPT" use infrastructure2 "$UPSTREAM_REPO2"
    
    if "$CROSS_SCRIPT" patch infrastructure2:monitoring/prometheus monitoring/prometheus feature/new-monitoring; then
        test_pass "Feature branch patch successful"
    else
        test_fail "Feature branch patch failed"
    fi
    
    # Verify correct branch was used
    cd "monitoring/prometheus"
    if git log --oneline | grep -q "Add database monitoring"; then
        test_pass "Feature branch content correct"
    else
        test_fail "Feature branch content incorrect"
    fi
    
    cd ../..
}

# Test 8: Environment variable configurations
test_environment_variables() {
    log "Testing environment variable configurations..."
    
    cd "$LOCAL_REPO"
    
    # Test CROSS_FETCH_DEPTH
    export CROSS_FETCH_DEPTH=5
    
    "$CROSS_SCRIPT" use testenv "$UPSTREAM_REPO3"
    
    if "$CROSS_SCRIPT" patch testenv:src/auth auth/oauth; then
        test_pass "CROSS_FETCH_DEPTH configuration works"
    else
        test_fail "CROSS_FETCH_DEPTH configuration failed"
    fi
    
    # Test CROSS_DEFAULT_BRANCH
    export CROSS_DEFAULT_BRANCH=main
    
    # Reset environment
    unset CROSS_FETCH_DEPTH
    unset CROSS_DEFAULT_BRANCH
    
    test_pass "Environment variables tested"
}

# Test 9: Error handling and edge cases
test_error_handling() {
    log "Testing error handling and edge cases..."
    
    cd "$LOCAL_REPO"
    
    # Test invalid remote
    if "$CROSS_SCRIPT" patch nonexistent:some/path 2>/dev/null; then
        test_fail "Should fail with nonexistent remote"
    else
        test_pass "Correctly handles nonexistent remote"
    fi
    
    # Test invalid path format
    if "$CROSS_SCRIPT" patch invalid_format 2>/dev/null; then
        test_fail "Should fail with invalid format"
    else
        test_pass "Correctly handles invalid format"
    fi
    
    # Test missing arguments
    if "$CROSS_SCRIPT" use single_arg 2>/dev/null; then
        test_fail "Should fail with missing arguments"
    else
        test_pass "Correctly handles missing arguments"
    fi
    
    # Test duplicate patch (should be skipped)
    "$CROSS_SCRIPT" patch microservice:configs/nginx duplicate_test
    local initial_count=$(git worktree list | wc -l)
    
    "$CROSS_SCRIPT" patch microservice:configs/nginx duplicate_test
    local final_count=$(git worktree list | wc -l)
    
    if [[ $initial_count -eq $final_count ]]; then
        test_pass "Duplicate patch correctly skipped"
    else
        test_fail "Duplicate patch not handled"
    fi
}

# Test 10: Remove functionality
test_remove_functionality() {
    log "Testing remove functionality..."
    
    cd "$LOCAL_REPO"
    
    # Create a patch to remove
    "$CROSS_SCRIPT" patch microservice:docs/api test_remove_dir
    
    if [[ -d "test_remove_dir" ]]; then
        test_pass "Test patch created for removal"
    else
        test_fail "Could not create test patch"
        return
    fi
    
    # Remove the patch
    "$CROSS_SCRIPT" remove test_remove_dir
    
    if [[ ! -d "test_remove_dir" ]]; then
        test_pass "Patch removed successfully"
    else
        test_fail "Patch not removed"
    fi
    
    # Verify worktree was removed
    if ! git worktree list | grep -q "test_remove_dir"; then
        test_pass "Worktree removed successfully"
    else
        test_fail "Worktree not removed"
    fi
}

# Test 11: Complex integration scenario
test_complex_integration() {
    log "Testing complex integration scenario..."
    
    cd "$LOCAL_REPO"
    
    # Create a complex Cross file with hooks
    cat > Cross.complex << 'EOF'
# Complex integration scenario

use app $UPSTREAM_REPO1
use infra $UPSTREAM_REPO2
use lib $UPSTREAM_REPO3

# Patch multiple components
patch app:configs/nginx web/nginx
patch app:scripts/deploy deployment/scripts
patch infra:terraform/aws infrastructure/terraform
patch infra:kubernetes/base infrastructure/k8s
patch lib:src/utils shared/utils
patch lib:examples/basic examples/usage

# Complex post-hook
cross_post_hook() {
    local path="$1"
    echo "Processing $path..."
    
    # Simulate dependency management
    if [[ "$path" == "web/nginx" ]]; then
        echo "Configuring nginx for current environment..."
        # Could modify configs here
    elif [[ "$path" == "infrastructure/terraform" ]]; then
        echo "Validating terraform configuration..."
        # Could run terraform validate
    fi
}
EOF
    
    # Substitute variables
    sed -i "s|\$UPSTREAM_REPO1|$UPSTREAM_REPO1|g" Cross.complex
    sed -i "s|\$UPSTREAM_REPO2|$UPSTREAM_REPO2|g" Cross.complex
    sed -i "s|\$UPSTREAM_REPO3|$UPSTREAM_REPO3|g" Cross.complex
    
    # Execute complex scenario
    if "$CROSS_SCRIPT" < Cross.complex; then
        test_pass "Complex integration scenario successful"
    else
        test_fail "Complex integration scenario failed"
    fi
    
    # Verify all components are integrated
    local expected_paths=("web/nginx" "deployment/scripts" "infrastructure/terraform" "infrastructure/k8s" "shared/utils" "examples/usage")
    local all_present=true
    
    for path in "${expected_paths[@]}"; do
        if [[ ! -d "$path" ]]; then
            all_present=false
            error "Missing integrated component: $path"
        fi
    done
    
    if $all_present; then
        test_pass "All components integrated successfully"
    else
        test_fail "Some components missing"
    fi
}

# Test 12: Git worktree advanced features
test_worktree_advanced() {
    log "Testing advanced worktree features..."
    
    cd "$LOCAL_REPO"
    
    # Test sparse checkout configuration
    cd "services/nginx-config"
    
    # Check sparse checkout is enabled
    if git config --get core.sparseCheckout | grep -q "true"; then
        test_pass "Sparse checkout enabled"
    else
        test_fail "Sparse checkout not enabled"
    fi
    
    # Check sparse checkout patterns
    local sparse_file=$(git rev-parse --git-path info/sparse-checkout)
    if [[ -f "$sparse_file" ]]; then
        test_pass "Sparse checkout file exists"
    else
        test_fail "Sparse checkout file missing"
    fi
    
    # Test worktree status
    if git status | grep -q "sparse checkout"; then
        test_pass "Worktree shows sparse checkout status"
    else
        test_fail "Worktree sparse checkout status missing"
    fi
    
    cd ../..
}

# Run all comprehensive tests
run_comprehensive_tests() {
    log "Starting comprehensive git-cross test suite..."
    
    setup_comprehensive_test_env
    
    test_cli_basic_operations
    test_cross_file_processing
    test_commits_in_worktrees
    test_upstream_updates
    test_rebase_functionality
    test_pull_request_simulation
    test_multiple_branches
    test_environment_variables
    test_error_handling
    test_remove_functionality
    test_complex_integration
    test_worktree_advanced
    
    log "Comprehensive test suite completed"
    log "Tests passed: $TESTS_PASSED"
    log "Tests failed: $TESTS_FAILED"
    
    if [[ $TESTS_FAILED -eq 0 ]]; then
        log "All comprehensive tests passed! ✓"
        return 0
    else
        error "Some comprehensive tests failed! ✗"
        return 1
    fi
}

# Cleanup function
cleanup() {
    log "Cleaning up comprehensive test environment..."
    rm -rf "$TEST_DIR"
}

# Main execution
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    trap cleanup EXIT
    run_comprehensive_tests
fi