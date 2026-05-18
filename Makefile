.PHONY: help init plan apply destroy deploy test clean fmt validate

# ─── Config ───────────────────────────────────────────────────────────────────
ENV        ?= dev
REGION     ?= us-east-1
TF_DIR     := terraform
BUILD_DIR  := .build
LAMBDA_DIR := lambda

# ─────────────────────────────────────────────────────────────────────────────
help: ## Show this help message
	@echo ""
	@echo "  Zero-Ops Ticket Platform — Makefile Commands"
	@echo ""
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | \
		awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-18s\033[0m %s\n", $$1, $$2}'
	@echo ""

# ─── Build ────────────────────────────────────────────────────────────────────
$(BUILD_DIR):
	@mkdir -p $(BUILD_DIR)

build: $(BUILD_DIR) ## Package Lambda functions into zip files
	@echo "📦 Packaging Lambda functions..."
	@zip -j $(BUILD_DIR)/purchase.zip $(LAMBDA_DIR)/purchase.py
	@zip -j $(BUILD_DIR)/payment.zip  $(LAMBDA_DIR)/payment.py
	@zip -j $(BUILD_DIR)/cleanup.zip  $(LAMBDA_DIR)/cleanup.py
	@echo "✅ Lambda packages ready in $(BUILD_DIR)/"

# ─── Terraform ────────────────────────────────────────────────────────────────
init: ## Initialize Terraform providers and backend
	@echo "🔧 Initializing Terraform..."
	@cd $(TF_DIR) && terraform init

fmt: ## Format all Terraform files
	@cd $(TF_DIR) && terraform fmt -recursive

validate: ## Validate Terraform configuration
	@cd $(TF_DIR) && terraform validate

plan: build ## Preview infrastructure changes
	@echo "🔍 Planning for ENV=$(ENV) in $(REGION)..."
	@cd $(TF_DIR) && terraform plan \
		-var="environment=$(ENV)" \
		-var="aws_region=$(REGION)" \
		-out=tfplan

apply: build ## Apply infrastructure changes
	@echo "🚀 Deploying ENV=$(ENV) to $(REGION)..."
	@cd $(TF_DIR) && terraform apply \
		-var="environment=$(ENV)" \
		-var="aws_region=$(REGION)" \
		-auto-approve
	@echo "✅ Deployment complete!"
	@cd $(TF_DIR) && terraform output

deploy: init fmt validate apply ## Full deploy: init + fmt + validate + apply
	@echo "🎉 Full deployment complete for ENV=$(ENV)"

destroy: ## Destroy all infrastructure (DANGER)
	@echo "⚠️  WARNING: This will destroy all resources for ENV=$(ENV)"
	@read -p "Type 'yes' to confirm: " confirm && [ "$$confirm" = "yes" ] || exit 1
	@cd $(TF_DIR) && terraform destroy \
		-var="environment=$(ENV)" \
		-var="aws_region=$(REGION)" \
		-auto-approve

# ─── Testing ──────────────────────────────────────────────────────────────────
test: ## Run k6 load test (requires k6 installed + API_URL set)
	@if ! command -v k6 &> /dev/null; then \
		echo "❌ k6 not found. Install: https://k6.io/docs/getting-started/installation/"; \
		exit 1; \
	fi
	@API_URL=$$(cd $(TF_DIR) && terraform output -raw api_endpoint 2>/dev/null || echo ""); \
	if [ -z "$$API_URL" ]; then \
		echo "❌ Could not read API URL from Terraform. Run 'make apply' first."; \
		exit 1; \
	fi; \
	echo "🔥 Running load test against $$API_URL"; \
	k6 run -e API_URL=$$API_URL tests/load-test.js

test-dry: ## Run a quick 10-VU smoke test
	@API_URL=$$(cd $(TF_DIR) && terraform output -raw api_endpoint 2>/dev/null || echo "http://localhost:3000"); \
	k6 run --vus 10 --duration 30s -e API_URL=$$API_URL tests/load-test.js

# ─── Utils ────────────────────────────────────────────────────────────────────
outputs: ## Print Terraform outputs
	@cd $(TF_DIR) && terraform output

logs-purchase: ## Tail Purchase Lambda logs
	@aws logs tail /aws/lambda/$(shell cd $(TF_DIR) && terraform output -raw purchase_lambda_arn | cut -d: -f7) --follow --region $(REGION)

logs-payment: ## Tail Payment Lambda logs
	@aws logs tail /aws/lambda/$(shell cd $(TF_DIR) && terraform output -raw payment_lambda_arn | cut -d: -f7) --follow --region $(REGION)

logs-cleanup: ## Tail Cleanup Lambda logs
	@aws logs tail /aws/lambda/$(shell cd $(TF_DIR) && terraform output -raw cleanup_lambda_arn | cut -d: -f7) --follow --region $(REGION)

clean: ## Remove build artifacts
	@rm -rf $(BUILD_DIR)
	@echo "🧹 Build artifacts cleaned"
