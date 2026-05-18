.PHONY: help build init fmt plan apply destroy test clean

# ─── Variables ──────────────────────────────────────────────────────────────
# Cleaned up region to match your main.tf (ca-central-1)
TF_DIR     := terraform
BUILD_DIR  := .build
LAMBDA_DIR := lambda

# ─── Help Menu ────────────────────────────────────────────────────────────────
help: ## Show available commands
	@echo "Available commands:"
	@echo "  make build     - Zip up Python Lambda files manually"
	@echo "  make init      - Initialize Terraform"
	@echo "  make fmt       - Format Terraform code files"
	@echo "  make plan      - Preview changes on AWS"
	@echo "  make apply     - Deploy everything to AWS"
	@echo "  make test      - Run the k6 load test script"
	@echo "  make destroy  - Tear down all AWS resources"
	@echo "  make clean     - Delete local build zip files"

# ─── Build Tasks ─────────────────────────────────────────────────────────────
build: ## Zip up the Python Lambda files
	@echo "Packaging Lambda files into zip archives..."
	@mkdir -p $(BUILD_DIR)
	cd $(LAMBDA_DIR) && zip ../$(BUILD_DIR)/purchase.zip purchase.py
	cd $(LAMBDA_DIR) && zip ../$(BUILD_DIR)/payment.zip payment.py
	cd $(LAMBDA_DIR) && zip ../$(BUILD_DIR)/cleanup.zip cleanup.py
	@echo "Zip files ready in $(BUILD_DIR)/ folder."

# ─── Terraform Tasks ──────────────────────────────────────────────────────────
init: ## Initialize Terraform working directory
	cd $(TF_DIR) && terraform init

fmt: ## Automatically format HCL layout spacing
	cd $(TF_DIR) && terraform fmt

plan: ## Check what changes Terraform wants to make on AWS
	cd $(TF_DIR) && terraform plan

apply: ## Deploy the infrastructure to your live AWS account
	cd $(TF_DIR) && terraform apply -auto-approve

destroy: ## Delete every resource in this project from AWS
	cd $(TF_DIR) && terraform destroy -auto-approve

# ─── Automation Testing ───────────────────────────────────────────────────────
test: ## Grab the active API URL from outputs and execute the k6 script
	@API_URL=$$(cd $(TF_DIR) && terraform output -raw api_endpoint 2>/dev/null); \
	if [ -z "$$API_URL" ]; then \
		echo "Error: Could not find api_endpoint. Run 'make apply' first."; \
		exit 1; \
	fi; \
	echo "Starting test execution against: $$API_URL"; \
	k6 run -e API_URL=$$API_URL tests/load-test.js

clean: ## Delete the local zip build folders
	rm -rf $(BUILD_DIR)
	@echo "Local zip build directories cleared."