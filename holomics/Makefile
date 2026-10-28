WEB_TAG ?= 1.0.0
IMAGE ?= quay.io/galaxy/holomics-gxit
APP_REVISION ?= cbe14e26b4afd0f6ced2227b92c41f49a9c2679a
PLANEMO ?= planemo

.PHONY: docker serve lint test
docker:
	docker build --build-arg APP_REVISION=$(APP_REVISION) -t $(IMAGE):$(WEB_TAG) -t holomics-gxit:latest .
serve:
	$(PLANEMO) serve --host 0.0.0.0 --port 8080 --job_workers 4 --docker --biocontainers --docker_run_extra_arguments '--add-host localhost:host-gateway' --galaxy_root $(HOME)/git/galaxy gxit/
lint:
	$(PLANEMO) lint gxit/
test:
	docker run --rm -v $(CURDIR)/tests:/tests:ro $(IMAGE):$(WEB_TAG) Rscript /tests/export_only.R
